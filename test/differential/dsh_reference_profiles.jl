using UUIDs: uuid4

const DSH_REFERENCE_COMMIT = "ce7073d51254c26cd63b22a60835b8f948deb447"
const DSH_REFERENCE_VERSION = "0.2.2-alpha.2"
const DSH_SHIPPED_PROFILES = ("web", "headless", "sdk", "sdk-minimal", "acp")

struct DSHProfile
    name::String
    command::Cmd
    patches::Vector{String}
    arguments::Vector{String}
    directory::String
    environment::Dict{String,String}
end

"""Describe an optional DSH composition, including third-party profiles, ordered overlays and app arguments."""
function DSHProfile(name::AbstractString="sdk"; command=`dsh`, patches=String[], arguments=String[],
        directory=pwd(), environment=Dict{String,String}(), home=nothing)
    values = Dict{String,String}(String(key) => String(value) for (key, value) in pairs(environment))
    isnothing(home) || (values["DSH_HOME"] = abspath(home))
    return DSHProfile(String(name), command, abspath.(String.(patches)), String.(arguments),
        abspath(directory), values)
end

"""Construct argv without a shell, preserving profile patch order and all application arguments."""
function dsh_command(profile::DSHProfile)
    overlays = String[]
    for patch in profile.patches
        append!(overlays, ["--patch", patch])
    end
    command = `$(profile.command) --profile $(profile.name) $overlays $(profile.arguments)`
    return addenv(Cmd(command; dir=profile.directory), profile.environment...)
end

"""Extract the text blocks of the final assistant message from validated DSH session events."""
function dsh_final_response(events)
    matching = Iterators.filter(event -> get(event, "type", nothing) == "assistant/message", Iterators.reverse(events))
    found = iterate(matching)
    isnothing(found) ? "" : join(block["text"] for block in first(found)["data"]["message"]["content"] if get(block, "type", nothing) == "text")
end
