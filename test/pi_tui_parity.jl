using Tachikoma
using CommonMark
using JSON

@testset "Pinned Pi interactive menu parity (red → green)" begin
    reference = get(ENV, "PI_REFERENCE", "")
    @test !isempty(reference) && isdir(reference)
    if !isempty(reference) && isdir(reference)
        oracle = joinpath(@__DIR__, "..", "parity", "pi_tui_oracle.mjs")
        result = JSON.parse(read(`node $oracle $reference`, String))
        terminal = Base.get_extension(JuliaForever2, :JuliaForever2TerminalExt)
        @test !isnothing(terminal)
        if !isnothing(terminal)
            app = terminal.App(JuliaForever2.default_kernel())
            pi_names = [item["name"] for item in result["commands"]]
            visible = [command.name for command in app.commands
                if !hasproperty(command, :visible) || command.visible]
            @test visible == pi_names
            @test isdefined(terminal, :menu_snapshot)
            @test isdefined(terminal, :register_prompt!)
            @test isdefined(terminal, :register_skill!)
            @test isdefined(terminal, :menu_action)
            @test isdefined(terminal, :complete_input!)
            if all(name -> isdefined(terminal, name),
                    (:menu_snapshot, :register_prompt!, :register_skill!, :menu_action, :complete_input!))
                for images in (false, true)
                    expected = result["settings"][images ? "withImages" : "noImages"]
                    actual = terminal.menu_snapshot(app; images,
                        models=[(provider="demo", id="alpha", reasoning=true)])
                    @test actual == expected

                    function check_actions(nodes, trail=String[])
                        for node in nodes
                            path = [trail; node["id"]]
                            @test terminal.menu_action(app, path) isa Function
                            if haskey(node, "choices")
                                for value in node["choices"]
                                    @test terminal.menu_action(app, [path; String(value)]) isa Function
                                end
                            end
                            haskey(node, "children") && check_actions(node["children"], path)
                        end
                    end
                    check_actions(actual, ["settings"])
                end

                @test [command.name for command in terminal.discover_commands(app)] ==
                    result["scenarios"]["default"]["names"]

                @test terminal.menu_action(app, ["settings", "skill-commands", "false"]) isa Function
                terminal.menu_action(app, ["settings", "skill-commands", "false"])()
                @test !app.menus.skill_commands_enabled
                terminal.menu_action(app, ["settings", "skill-commands", "true"])()
                @test app.menus.skill_commands_enabled

                terminal.register_prompt!(app, "prompt-example", "Example prompt")
                terminal.register_command!(app, terminal.CommandSpec("ext-example",
                    "Extension command", (app, args) -> (app.status = String(args))))
                terminal.register_skill!(app, "example", "/fixture/SKILL.md"; description="Example skill")
                @test [command.name for command in terminal.discover_commands(app)] ==
                    result["scenarios"]["installed"]["names"]
                @test "skill:example" in [command.name for command in terminal.discover_commands(app)]
                contributed = terminal.CommandSpec("plugin-example", "Plugin command",
                    (app, arguments) -> (app.status = String(arguments)))
                JuliaForever2.install!(app.session.kernel,
                    JuliaForever2.ComponentSpec(:slash_commands, [contributed]))
                @test "plugin-example" in [command.name for command in terminal.discover_commands(app)]
                JuliaForever2.remove!(app.session.kernel, :slash_commands)
                @test !("plugin-example" in [command.name for command in terminal.discover_commands(app)])
                terminal.set_skill_commands!(app, false)
                @test [command.name for command in terminal.discover_commands(app)] ==
                    result["scenarios"]["disabledSkills"]["names"]
                terminal.set_skill_commands!(app, true)

                Tachikoma.set_text!(app.input, "/set")
                Tachikoma.update!(app, Tachikoma.KeyEvent(:tab))
                @test Tachikoma.text(app.input) == result["scenarios"]["default"]["completed"]
                terminal.command!(app, "new")
                @test occursin("New session started", app.status)
            end
        end
    end
end
