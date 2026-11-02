using Tachikoma, CommonMark, JSON

const VisualTerminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)

"""Select the rendered settings scope without treating other menus as verified."""
function settings_visual_frame(frame)
    id = frame["id"]
    startswith(id, "settings.") && (occursin(r"^settings\.[^.]+\.selected$", id) || occursin(r"^settings\.[^.]+\.cycle-[0-9]+$", id) ||
        id in ("settings.no-images.main", "settings.images.main") || startswith(id, "settings.search.") ||
        startswith(id, "settings.warnings."))
end

"""Replay the same public menu inputs used by the original pinned component oracle."""
function candidate_settings_frame(frame, directory)
    id, width = frame["id"], frame["width"]
    app = VisualTerminal.App(; settings_dir=directory, theme_fallback="dark")
    VisualTerminal.open_menu!(app, "settings")
    setting = split(id, '.')[2]
    app.menus.images = setting in ("images", "show-images", "image-width-cells")
    if endswith(id, ".selected") || occursin(".cycle-", id)
        app.menus.cursor = findfirst(item -> item.id == setting, VisualTerminal.settings_definitions(app.menus.images))
    elseif setting == "search"
        Tachikoma.set_text!(app.menus.search, String(split(id, '.')[3]))
    end
    if occursin(".cycle-", id)
        for _ in 1:parse(Int, last(split(id, '-')))
            VisualTerminal.settings_input!(app, Tachikoma.KeyEvent(:enter))
        end
    end
    if startswith(id, "settings.warnings.") && !endswith(id, ".selected")
        app.menus.cursor = findfirst(item -> item.id == "warnings", VisualTerminal.settings_definitions(false))
        VisualTerminal.settings_input!(app, Tachikoma.KeyEvent(:enter))
        if id in ("settings.warnings.toggled", "settings.warnings.back-restores-selection")
            VisualTerminal.settings_input!(app, Tachikoma.KeyEvent(' '))
        end
        if id == "settings.warnings.back-restores-selection"
            VisualTerminal.settings_input!(app, Tachikoma.KeyEvent(:escape))
        end
    end
    lines = VisualTerminal.settings_lines(app, width)
    ansi = map(lines) do row
        sprint() do io
            for span in row
                Tachikoma.write_style(io, span.style)
                print(io, span.content)
            end
            print(io, "\e[0m")
        end
    end
    close(app.session)
    (id=id, width=width, ansiLines=ansi)
end

@testset "Original pinned settings renderer: exact terminal cells and transitions" begin
    reference = get(ENV, "PI_REFERENCE", "")
    @test isdir(reference)
    if isdir(reference)
        mktempdir() do directory
            oracle = joinpath(@__DIR__, "..", "parity", "pi_visual_oracle.mjs")
            comparator = joinpath(@__DIR__, "..", "parity", "compare_terminal_cells.mjs")
            full = joinpath(directory, "original.json")
            run(`node $oracle $reference $full`)
            original = JSON.parsefile(full)
            frames = filter(settings_visual_frame, original["snapshots"])
            expected = joinpath(directory, "settings-original.json")
            candidate = joinpath(directory, "settings-native.json")
            write(expected, JSON.json((snapshots=frames,)))
            actual = map(enumerate(frames)) do (index, frame)
                candidate_settings_frame(frame, joinpath(directory, "settings-$index"))
            end
            write(candidate, JSON.json((snapshots=actual,)))
            report = joinpath(directory, "settings-cells.json")
            run(pipeline(`node $comparator $expected $candidate $report`; stdout=devnull))
            result = JSON.parsefile(report)
            @test result["checked"] == length(frames)
            @test result["matching"] == length(frames)
            @test result["differing"] == 0
            @test isempty(result["missingFrames"])
            evidence = get(ENV, "PI_VISUAL_EVIDENCE_DIR", "")
            if !isempty(evidence)
                mkpath(evidence)
                for path in (full, expected, candidate, report)
                    cp(path, joinpath(evidence, basename(path)); force=true)
                end
            end
        end
    end
end
