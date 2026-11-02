using Test, JuliaForever2
@testset "Queued delivery obeys actual synchronous journal ownership and preserves rejected work" begin
    JF=JuliaForever2
    @test isdefined(JF,:bind_history_journal!)
    mktempdir() do dir
        path=joinpath(dir,"journal.txt");write(path,"")
        calls=Ref(0)
        session=Session(Kernel((messages,session)->begin calls[]+=1;Answer("done");end))
        JF.bind_history_journal!(session,(owner,operation,args...)->begin
            if operation==:append
                message=args[1]
                message.content=="reject" && error("Durable journal rejected input")
                open(path,"a") do io
                    println(io,message.content)
                end
            end
            nothing
        end)
        @test JF.set_input_queue_mode!(session,:steering,"all").ok
        @test JF.queue_input!(session,"first").ok
        @test JF.queue_input!(session,"reject").ok
        handle=submit_turn!(session,"initial")
        wait(handle;throw=false)
        @test istaskfailed(handle)
        @test calls[]==0
        @test readlines(path)==["initial","first"]
        @test [m.content for m in session.messages]==["initial","first"]
        @test [item.message.content for item in JF.pending_input_snapshot(session).steering]==["reject"]
        JF.unbind_history_journal!(session)
        JF.bind_history_journal!(session,(owner,operation,args...)->begin
            operation==:append && open(io->println(io,args[1].content),path,"a")
            nothing
        end)
        @test fetch(JF.submit_queued_turn!(session)).ok
        @test readlines(path)==["initial","first","reject","done"]
        @test isempty(JF.peek_pending_inputs(session))
        @test calls[]==1
        JF.unbind_history_journal!(session);close(session)
    end
end
