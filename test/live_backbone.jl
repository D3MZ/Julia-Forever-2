using JuliaForever2
using Test

@testset "Live agent builds a stateful component" begin
    mktempdir() do dir
        cd(dir) do
            kernel = JuliaForever2.default_kernel(JuliaForever2.CodexProvider())
            session = Session(kernel)
            path = joinpath(dir, "word_tally.jl")
            prompt = """
            Build and load a new Julia plugin yourself using code mode. Work only in the current
            temporary directory and do not call external commands or network services. Write the
            plugin to $(repr(path)) and include it in this session. It must install a component
            named :word_tally whose mutable state has integer fields :turns and :words. Replace
            the :loop component with a wrapper that increments :turns and adds the number of
            whitespace-delimited words in the prompt to :words for each future turn, then delegates
            to JuliaForever2.default_loop!(session, prompt, max_steps). Declare the state component
            as a dependency of the loop. You have kernel, session, include, ComponentSpec,
            install!, and component available. Do not merely describe the plugin: write and load it.
            Finish with a short answer when it is installed.
            """
            created = run_turn!(session, prompt; max_steps=8)
            for message in session.messages[2:end]
                println("[", message.role, "] ", message.content)
            end
            @test created.ok
            @test isfile(path)
            state = component(kernel, :word_tally)
            @test !isnothing(state)
            if !isnothing(state) && hasproperty(state, :turns) && hasproperty(state, :words)
                turns, words = state.turns, state.words
                first = run_turn!(session, "alpha beta"; max_steps=4)
                @test first.ok
                @test state.turns == turns + 1
                @test state.words == words + 2
                second = run_turn!(session, "gamma delta epsilon"; max_steps=4)
                @test second.ok
                @test state.turns == turns + 2
                @test state.words == words + 5
                @test !remove!(kernel, :word_tally).ok
                println("Agent-created plugin source:\n", read(path, String))
            else
                @test false
            end
        end
    end
end
