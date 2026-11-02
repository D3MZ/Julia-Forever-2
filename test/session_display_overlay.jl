using Test, JuliaForever2
const TDO=JuliaForever2
for (name,file) in ((:SessionTimeline,"session_timeline.jl"),(:TimelineContextProjection,"session_context.jl"),(:TimelineDisplayProjection,"session_display.jl"))
    isdefined(TDO,name) || Base.include(TDO,joinpath(@__DIR__,"..","src/core",file))
end
@testset "Native display edit overlays preserve imported Pi and raw archives" begin
    timeline=TDO.SessionTimeline(pwd())
    own=TDO.timeline_append_message!(timeline,TDO.timeline_archive_message(Message(:assistant,"original",:code)))
    foreign=TDO.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"foreign raw"))
    original=TDO.timeline_entries(timeline)
    mark=Dict("format"=>"JuliaForever2.context-edit.v1","display"=>true)
    edit=TDO.timeline_append!(timeline,Dict("type"=>"context_edit","targetId"=>own,"replacement"=>Dict("content"=>"native edited"),"jf2"=>mark))
    TDO.timeline_append_context_edit!(timeline,foreign,Dict("content"=>"foreign effective"))
    projection=TDO.timeline_display_projection(timeline)
    overlays=TDO.timeline_display_overlays(projection)
    @test keys(overlays)==Set([own])
    @test overlays[own].content=="native edited"
    @test overlays[own].edit_entry_id==edit
    @test only(filter(item->item.source_entry_id==own,projection.items)).payload==original[1]["message"]
    restored=TDO.timeline_from_rows([TDO.timeline_header(timeline);TDO.timeline_entries(timeline)])
    @test TDO.timeline_display_overlays(TDO.timeline_display_projection(restored))[own].content=="native edited"
    @test isempty(TDO.timeline_display_overlays(TDO.timeline_display_projection(timeline;leaf=foreign)))
    TDO.timeline_append!(timeline,Dict("type"=>"context_edit","targetId"=>foreign,"replacement"=>Dict("content"=>"spoof"),"jf2"=>mark))
    @test_throws ErrorException TDO.timeline_display_overlays(TDO.timeline_display_projection(timeline))
end

@testset "Native code-result overlays, roundtrip and invalid marker rejection" begin
    timeline=TDO.SessionTimeline(pwd())
    result=Message(:code_result,"before",:text;metadata=ExecutionResult(true,"before",42))
    id=TDO.timeline_append_message!(timeline,TDO.timeline_archive_message(result))
    mark=Dict("format"=>"JuliaForever2.context-edit.v1","display"=>true)
    TDO.timeline_append!(timeline,Dict("type"=>"context_edit","targetId"=>id,"replacement"=>Dict("content"=>"after"),"jf2"=>mark))
    projection=TDO.timeline_display_projection(timeline)
    @test TDO.timeline_display_overlays(projection)[id].content=="after"
    @test only(TDO.timeline_runtime_messages(timeline)).content=="after"
    @test projection.items[1].payload["content"]=="before"
    mktempdir() do directory
        TDO.save_timeline!(TDO.TimelineStore(directory),timeline)
        loaded=TDO.load_timeline(TDO.TimelineStore(directory),timeline.identity.id)
        @test TDO.timeline_display_overlays(TDO.timeline_display_projection(loaded))[id].content=="after"
        @test only(TDO.timeline_runtime_messages(loaded)).content=="after"
    end
    invalid=TDO.timeline_from_rows([TDO.timeline_header(timeline);TDO.timeline_entries(timeline)])
    TDO.timeline_append!(invalid,Dict("type"=>"context_edit","targetId"=>id,"replacement"=>Dict("content"=>"bad","role"=>"system"),"jf2"=>mark))
    @test_throws ErrorException TDO.timeline_display_overlays(TDO.timeline_display_projection(invalid))
    @test TDO.timeline_display_overlays(projection)[id].content=="after"
end
