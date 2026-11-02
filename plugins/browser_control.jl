module BrowserControl

using JuliaForever2

const JF = JuliaForever2
const BRIDGE = joinpath(@__DIR__, "browser_control.cjs")
const PLAYWRIGHT_VERSION = "1.50.1"

function dependency_directory()
    data = get(ENV, "XDG_DATA_HOME", "")
    root = isempty(data) ? joinpath(homedir(), ".local", "share") : data
    joinpath(root, "juliaforever2", "browser-control")
end

playwright_directory(directory=dependency_directory()) = joinpath(directory, "node_modules", "playwright")

function command_path(command::AbstractString)
    path = Sys.which(command)
    isnothing(path) ? nothing : String(path)
end

function setup_browser_control!(; node="node", npm="npm", directory=dependency_directory(), install_browser=true)
    node_path, npm_path = command_path(node), command_path(npm)
    if isnothing(node_path) || isnothing(npm_path)
        (ok=false, reason="Node.js and npm are required; install them and retry setup.")
    else
        mkpath(directory)
        dependency = "playwright@" * PLAYWRIGHT_VERSION
        command = `$npm_path install --prefix $directory --no-save --no-audit --no-fund --ignore-scripts --package-lock=false $dependency`
        installed = success(run(ignorestatus(command)))
        if !installed
            (ok=false, reason="Playwright installation failed; see npm output.")
        elseif install_browser
            cli = joinpath(playwright_directory(directory), "cli.js")
            browser = success(run(ignorestatus(`$node_path $cli install chromium`)))
            browser ? (ok=true, reason="") : (ok=false, reason="Playwright Chromium installation failed; see installer output.")
        else
            (ok=true, reason="")
        end
    end
end

mutable struct Browser
    process::Base.Process
    lock::ReentrantLock
    closed::Bool
    sequence::Int
    timeout::Float64
end

function stop!(browser::Browser)
    browser.closed = true
    if process_running(browser.process)
        if Sys.iswindows()
            kill(browser.process)
        else
            ccall(:kill, Cint, (Cint, Cint), -getpid(browser.process), Base.SIGTERM)
        end
        timedwait(() -> !process_running(browser.process), 2.0; pollint=0.02)
        if process_running(browser.process)
            if Sys.iswindows()
                kill(browser.process, Base.SIGKILL)
            else
                ccall(:kill, Cint, (Cint, Cint), -getpid(browser.process), Base.SIGKILL)
            end
        end
    end
    wait(browser.process)
    nothing
end

function Base.close(browser::Browser)
    lock(browser.lock) do
        browser.closed || stop!(browser)
    end
    nothing
end

function exchange(browser::Browser, method::AbstractString, params::AbstractDict)
    lock(browser.lock) do
        if browser.closed || !process_running(browser.process)
            JF.RpcError(-32000, "The owned browser is closed")
        else
            browser.sequence += 1
            id = browser.sequence
            worker = Threads.@spawn begin
                println(browser.process, JF.JSONCodec.JSON.json(Dict("id" => id, "method" => String(method), "params" => params)))
                flush(browser.process)
                JF.parse_json(readline(browser.process))
            end
            ready = timedwait(() -> istaskdone(worker), browser.timeout; pollint=0.01)
            if ready == :timed_out
                stop!(browser)
                wait(worker; throw=false)
                JF.RpcError(-32000, "Browser operation timed out; the owned browser was stopped")
            elseif istaskfailed(worker)
                stop!(browser)
                JF.RpcError(-32000, "Owned browser process ended unexpectedly")
            else
                frame = fetch(worker)
                if !(frame isa AbstractDict) || get(frame, "id", nothing) != id
                    stop!(browser)
                    JF.RpcError(-32000, "Invalid owned browser response; browser stopped")
                elseif get(frame, "ok", false) === true
                    get(frame, "result", nothing)
                else
                    JF.RpcError(-32000, string(get(frame, "error", "Browser operation failed")))
                end
            end
        end
    end
end

function launch(; node="node", playwright=playwright_directory(), executable="", headless=true, timeout=30.0)
    node_path = command_path(node)
    if isnothing(node_path)
        (ok=false, reason="Node.js is required; install it and retry.", browser=nothing)
    else
        command = addenv(`$node_path $BRIDGE`, "JF2_PLAYWRIGHT_MODULE" => String(playwright),
            "JF2_BROWSER_EXECUTABLE" => String(executable), "JF2_BROWSER_HEADLESS" => headless ? "1" : "0")
        process = open(pipeline(detach(command); stderr=devnull), "r+")
        browser = Browser(process, ReentrantLock(), false, 0, Float64(timeout))
        result = exchange(browser, "start", Dict{String,Any}())
        if result isa JF.RpcError
            close(browser)
            reason = occursin("Cannot find module", result.message) ?
                "Playwright not found; run BrowserControl.setup_browser_control!() first." : result.message
            (ok=false, reason, browser=nothing)
        else
            (ok=true, reason="", browser)
        end
    end
end

function install_browser_control!(kernel::JF.Kernel; kwargs...)
    launched = launch(; kwargs...)
    if !launched.ok
        (ok=false, reason=launched.reason)
    else
        result = JF.install!(kernel, JF.ComponentSpec(:browser_control, launched.browser; cleanup=close))
        result.ok || close(launched.browser)
        result
    end
end

function call!(kernel::JF.Kernel, method::AbstractString, params::AbstractDict=Dict{String,Any}())
    lease = JF.acquire!(kernel, :browser_control)
    if isnothing(lease)
        JF.RpcError(-32601, "Browser control is not installed")
    else
        worker = Threads.@spawn exchange(lease.value, method, params)
        wait(worker; throw=false)
        result = istaskfailed(worker) ? JF.RpcError(-32000, "Browser operation failed") : fetch(worker)
        cleanup = Threads.@spawn JF.release!(lease)
        wait(cleanup; throw=false)
        istaskfailed(cleanup) ? JF.RpcError(-32000, "Browser cleanup failed") : result
    end
end

end
