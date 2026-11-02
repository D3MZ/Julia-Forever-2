using Test, JuliaForever2
using JuliaForever2: append_message!, replace_message!, clear_history!

@testset "Durable history observer boundary and per-session isolation" begin
    kernel = Kernel()
    first = Session(kernel)
    second = Session(kernel)
    observed = Any[]
    callback = (session, operation, args...) -> push!(observed, (session.runtime.id, operation, length(session.messages), args))
    JuliaForever2.bind_history_journal!(first, callback)
    @test_throws ErrorException JuliaForever2.bind_history_journal!(first, callback)
    append_message!(first, Message(:user, "one"))
    append_message!(second, Message(:user, "two"))
    @test length(observed) == 1
    @test observed[1][2:3] == (:append, 0)
    replace_message!(first, 1, Message(:user, "updated"))
    @test observed[2][2:3] == (:replace, 1)
    clear_history!(first)
    @test observed[3][2:3] == (:clear, 1)
    @test isempty(first.messages) && length(second.messages) == 1
    JuliaForever2.unbind_history_journal!(first)
    JuliaForever2.bind_history_journal!(first, (args...) -> error("Durability failed"))
    @test_throws ErrorException append_message!(first, Message(:user, "not committed"))
    @test isempty(first.messages)
    JuliaForever2.unbind_history_journal!(first)
    append_message!(first, Message(:user, "unobserved"))
    @test length(observed) == 3
    close(first); close(second); close(kernel)
end
