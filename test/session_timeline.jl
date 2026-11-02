using Test
using JuliaForever2
using JSON

const TL = JuliaForever2
if !isdefined(TL, :SessionTimeline)
    Base.include(TL, joinpath(@__DIR__, "..", "src", "core", "session_timeline.jl"))
end
const TIMELINE_ORACLE = get(ENV, "JF2_TIMELINE_ORACLE", "")
const TIMELINE_CAPTURE = raw"""{"schemaVersion":1,"pin":"2c8d1feb147f6b3d97e855da803bfe7b19f3c403","sourceHashes":{"packages/coding-agent/src/core/session-manager.ts":"51398209d139707e18c7c2d33a8225813d7db1337800631be410b0aca412e597","packages/coding-agent/src/core/session-export.ts":"8ec53e13bd4bc9097e4f7640e2fd2e58ffbbdcadce6df5efdf5cb5622f98d285"},"fixture":[{"type":"session","version":3,"id":"11111111-1111-4111-8111-111111111111","timestamp":"2026-11-01T20:00:00.000Z","cwd":"/tmp"},{"type":"message","id":"u1","parentId":null,"timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U1"}],"timestamp":1793563200000}},{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}},{"type":"custom","id":"c1","parentId":"a1","timestamp":"2026-11-01T20:00:00.000Z","customType":"fixture.opaque","data":{"nested":[null,true,"λ"]}},{"type":"message","id":"u2","parentId":"c1","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U2"}],"timestamp":1793563200000}},{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A2"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001}},{"type":"label","id":"l1","parentId":"a2","timestamp":"2026-11-01T20:00:00.000Z","targetId":"u1","label":"bookmark"},{"type":"session_info","id":"n1","parentId":"l1","timestamp":"2026-11-01T20:00:00.000Z","name":"Example session"}],"snapshots":{"initial":{"branch":["u1","a1","c1","u2","a2","l1","n1"],"name":"Example session","label":"bookmark"},"branch":{"retainedIds":["u1","a1","c1","u2","a2","l1","n1"],"branch":["u1","a1","new"],"parent":"a1"},"forkBefore":{"contents":[{"role":"user","content":[{"type":"text","text":"U1"}],"timestamp":1793563200000},{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},{"type":"custom","id":"c1","parentId":"a1","timestamp":"2026-11-01T20:00:00.000Z","customType":"fixture.opaque","data":{"nested":[null,true,"λ"]}}],"ids":["u1","a1","c1"],"label":"bookmark","freshId":true,"parent":true},"clone":{"ids":["u1","a1","c1","u2","a2","n1"],"labels":[{"targetId":"u1","label":"bookmark"}],"name":"Example session","freshId":true},"export":{"headerIdentity":{"id":"11111111-1111-4111-8111-111111111111","cwd":"/tmp","version":3},"entries":[{"type":"message","id":"u1","parentId":null,"timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U1"}],"timestamp":1793563200000}},{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}},{"type":"custom","id":"c1","parentId":"a1","timestamp":"2026-11-01T20:00:00.000Z","customType":"fixture.opaque","data":{"nested":[null,true,"λ"]}},{"type":"message","id":"u2","parentId":"c1","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U2"}],"timestamp":1793563200000}},{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A2"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001}},{"type":"label","id":"l1","parentId":"a2","timestamp":"2026-11-01T20:00:00.000Z","targetId":"u1","label":"bookmark"},{"type":"session_info","id":"n1","parentId":"l1","timestamp":"2026-11-01T20:00:00.000Z","name":"Example session"}]},"names":{"normalized":"First Second","cleared":null},"legacy":{"version":3,"id":"safe-custom.session_1","parents":[null,1,2,3],"firstKeptIndex":2,"extra":{"preserve":[1,"two",{"v":true}]}},"rich":{"bash":{"role":"bashExecution","command":"printf ok","output":"ok","exitCode":0,"cancelled":false,"truncated":false,"timestamp":1793563200000,"excludeFromContext":true},"edit":{"type":"context_edit","targetId":"a1","replacement":{"content":[{"type":"text","text":"Revised"}]}},"hide":{"type":"context_edit","targetId":"u2","replacement":null},"rejectsBashEdit":true,"rejectsBadContent":true,"rejectsOffBranchEdit":true},"tree":{"initial":[{"entry":{"type":"message","id":"u1","parentId":null,"timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U1"}],"timestamp":1793563200000}},"children":[{"entry":{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}},"children":[{"entry":{"type":"custom","id":"c1","parentId":"a1","timestamp":"2026-11-01T20:00:00.000Z","customType":"fixture.opaque","data":{"nested":[null,true,"λ"]}},"children":[{"entry":{"type":"message","id":"u2","parentId":"c1","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U2"}],"timestamp":1793563200000}},"children":[{"entry":{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"A2"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001}},"children":[{"entry":{"type":"label","id":"l1","parentId":"a2","timestamp":"2026-11-01T20:00:00.000Z","targetId":"u1","label":"bookmark"},"children":[{"entry":{"type":"session_info","id":"n1","parentId":"l1","timestamp":"2026-11-01T20:00:00.000Z","name":"Example session"},"children":[]}]}]}]}]}]}],"label":"bookmark","labelTimestamp":"2026-11-01T20:00:00.000Z"}],"fixture":[{"type":"session","version":3,"id":"11111111-1111-4111-8111-111111111111","timestamp":"2026-11-01T20:00:00.000Z","cwd":"/tmp"},{"type":"message","id":"u1","parentId":null,"timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U1"}],"timestamp":1793563200000}},{"type":"message","id":"late","parentId":"u1","timestamp":"2026-11-01T20:00:00.100Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}},{"type":"message","id":"early","parentId":"u1","timestamp":"2026-11-01T20:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}}],"ordered":[{"entry":{"type":"message","id":"u1","parentId":null,"timestamp":"2026-11-01T20:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"U1"}],"timestamp":1793563200000}},"children":[{"entry":{"type":"message","id":"early","parentId":"u1","timestamp":"2026-11-01T20:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}},"children":[]},{"entry":{"type":"message","id":"late","parentId":"u1","timestamp":"2026-11-01T20:00:00.100Z","message":{"role":"assistant","content":[{"type":"text","text":"A1"},{"type":"thinking","thinking":"opaque","thinkingSignature":"sig"}],"api":"openai-responses","provider":"openai","model":"fixture","usage":{"input":2,"output":3},"stopReason":"stop","timestamp":1793563200001},"extra":{"preserve":[1,"two",{"v":true}]}},"children":[]}]}]}}}"""
timeline_oracle() = isempty(TIMELINE_ORACLE) ? JSON.parse(TIMELINE_CAPTURE) : JSON.parsefile(TIMELINE_ORACLE)

@testset "Original Pi session timeline differential" begin
    oracle = timeline_oracle()
    @test oracle["pin"] == "2c8d1feb147f6b3d97e855da803bfe7b19f3c403"
    @test isdefined(TL, :SessionTimeline)
    if isdefined(TL, :SessionTimeline)
        fixture = join(JSON.json.(oracle["fixture"]), "\n") * "\n"
        timeline = TL.parse_timeline_jsonl(fixture)
        @test [entry["id"] for entry in TL.timeline_branch(timeline)] == oracle["snapshots"]["initial"]["branch"]
        @test TL.timeline_name(timeline) == oracle["snapshots"]["initial"]["name"]
        @test TL.timeline_label(timeline, "u1") == oracle["snapshots"]["initial"]["label"]
        original = TL.timeline_entries(timeline)
        TL.timeline_branch!(timeline, "a1")
        TL.timeline_append_message!(timeline, Dict("role"=>"user", "content"=>"Alternative"); id="new")
        @test [entry["id"] for entry in TL.timeline_branch(timeline)] == oracle["snapshots"]["branch"]["branch"]
        @test TL.timeline_entries(timeline)[1:length(original)] == original
        source = TL.parse_timeline_jsonl(fixture)
        fork = TL.timeline_fork(source, "u2")
        @test fork.editor_text == "U2"
        @test [entry["id"] for entry in TL.timeline_branch(fork.timeline) if entry["type"] != "label"] == oracle["snapshots"]["forkBefore"]["ids"]
        @test TL.timeline_label(fork.timeline, "u1") == oracle["snapshots"]["forkBefore"]["label"]
        @test TL.timeline_header(fork.timeline)["id"] != TL.timeline_header(source)["id"]
        clone = TL.timeline_clone(source)
        @test [entry["id"] for entry in TL.timeline_branch(clone) if entry["type"] != "label"] == oracle["snapshots"]["clone"]["ids"]
        @test TL.timeline_name(clone) == oracle["snapshots"]["clone"]["name"]
        exported = TL.timeline_export_jsonl(source)
        rows = JSON.parse.(filter(!isempty, split(exported, '\n')))
        @test rows[2:end] == oracle["snapshots"]["export"]["entries"]
        @test TL.timeline_entries(TL.parse_timeline_jsonl(exported)) == TL.timeline_entries(source)
    end
end

@testset "Timeline persistence, failure atomicity and strict input" begin
    @test TL.timeline_timestamp(0) == "1970-01-01T00:00:00.000Z"
    @test TL.timeline_timestamp(951782400) == "2000-02-29T00:00:00.000Z"
    @test TL.timeline_timestamp(-0.001) == "1969-12-31T23:59:59.999Z"
    mktempdir() do directory
        store = TL.TimelineStore(joinpath(directory, "sessions"))
        timeline = TL.SessionTimeline(directory)
        @test TL.timeline_leaf(timeline) === nothing
        @test isempty(TL.timeline_tree(timeline))
        @test_throws ErrorException TL.timeline_clone(timeline)
        user = Dict("role"=>"user", "content"=>Any[Dict("type"=>"text","text"=>"hello"),Dict("type"=>"image","data"=>"AA==","mimeType"=>"image/png")], "timestamp"=>1)
        first = TL.timeline_append_message!(timeline, user; id="u1")
        user["content"][1]["text"] = "mutated caller"
        @test TL.timeline_entry(timeline,first)["message"]["content"][1]["text"] == "hello"
        TL.timeline_append_message!(timeline,Dict("role"=>"assistant","content"=>"answer"); id="a1")
        path = TL.save_timeline!(store,timeline)
        @test isfile(path)
        @test (filemode(path) & 0o777) == 0o600
        @test (filemode(store.directory) & 0o777) == 0o700
        restored = TL.load_timeline(store, timeline.identity.id)
        @test TL.timeline_header(restored) == TL.timeline_header(timeline)
        @test TL.timeline_entries(restored) == TL.timeline_entries(timeline)
        TL.timeline_branch!(timeline,"u1")
        @test TL.timeline_leaf(TL.load_timeline(store,timeline.identity.id)) == "u1"
        old = TL.timeline_entries(restored)
        @test_throws TaskFailedException TL.timeline_name!(restored,"stale")
        @test TL.timeline_entries(restored) == old
        @test !ispath(path*".lock")
        TL.timeline_append_custom!(timeline,"plugin.data",Dict("values"=>Any[1,true,nothing,"λ"]); id="custom")
        TL.timeline_label!(timeline,"u1","marker"; id="label")
        @test TL.timeline_label(timeline,"u1") == "marker"
        TL.timeline_label!(timeline,"u1",nothing; id="unlabel")
        @test TL.timeline_label(timeline,"u1") === nothing
        TL.timeline_name!(timeline,"  A name  "; id="name")
        @test TL.timeline_name(timeline) == "A name"
        summaries = TL.list_timelines(store)
        @test length(summaries) == 1
        @test summaries[1].name == "A name"
        @test summaries[1].messages == 2
        @test isempty(TL.list_timelines(store;cwd=dirname(directory)))
        TL.timeline_branch!(timeline,nothing)
        @test isempty(TL.timeline_branch(timeline))
        @test length(TL.timeline_entries(timeline)) == 6
        @test TL.timeline_leaf(TL.load_timeline(store,timeline.identity.id)) === nothing
        TL.timeline_branch!(timeline,"name")
        copy = TL.timeline_entries(timeline)
        copy[1]["message"]["content"][1]["text"]="mutated snapshot"
        @test TL.timeline_entry(timeline,"u1")["message"]["content"][1]["text"] == "hello"
        header = TL.timeline_header(timeline); header["id"]="tampered"
        @test TL.timeline_header(timeline)["id"] != "tampered"
        source = joinpath(directory,"export.jsonl")
        TL.export_timeline!(timeline,source)
        before = read(source,String)
        @test_throws TaskFailedException TL.export_timeline!(timeline,source)
        @test read(source,String) == before
        other = TL.TimelineStore(joinpath(directory,"imports"))
        imported = TL.import_timeline!(other,source)
        @test TL.timeline_header(imported) == TL.timeline_header(timeline)
        @test TL.timeline_entries(imported) == TL.timeline_branch(timeline)
        @test_throws TaskFailedException TL.import_timeline!(other,source)
        @test length(TL.list_timelines(other)) == 1
        before_entries = TL.timeline_entries(timeline)
        before_disk = read(path,String)
        @test_throws ErrorException TL.timeline_branch!(timeline,"missing")
        @test_throws ErrorException TL.timeline_append_message!(timeline,Dict("role"=>"user","content"=>"duplicate");id="u1")
        @test_throws ErrorException TL.timeline_label!(timeline,"missing","label")
        @test_throws ErrorException TL.timeline_append!(timeline,Dict("type"=>"custom","customType"=>"bad","id"=>"override"))
        @test_throws ErrorException TL.timeline_fork(timeline,"a1")
        @test TL.timeline_entries(timeline) == before_entries
        @test read(path,String) == before_disk
        mkdir(path*".lock")
        @test_throws Base.IOError TL.timeline_name!(timeline,"locked")
        @test read(path,String) == before_disk
        @test TL.timeline_name(timeline) == "A name"
        rm(path*".lock")
        link = joinpath(directory,"link.jsonl"); symlink(source,link)
        @test_throws ErrorException TL.import_timeline!(other,link)
        @test_throws ErrorException TL.import_timeline!(other,source;max_bytes=4)
        @test_throws ErrorException TL.load_timeline(store,"../escape")
        @test_throws ErrorException TL.export_timeline!(timeline,joinpath(directory,"missing","x"))
    end
    fixture = timeline_oracle()["fixture"]
    jsonl(rows) = join(JSON.json.(rows),"\n")*"\n"
    @test_throws ErrorException TL.parse_timeline_jsonl("")
    @test_throws ErrorException TL.parse_timeline_jsonl("{bad}\n")
    @test_throws ErrorException TL.parse_timeline_jsonl("[]\n")
    @test_throws ErrorException TL.parse_timeline_jsonl(jsonl(fixture)*"bad\n")
    @test_throws ErrorException TL.parse_timeline_jsonl(jsonl(fixture); max_bytes=8)
    for invalid in [
        (rows -> rows[1]["version"]=4),
        (rows -> rows[1]["id"]="../escape"),
        (rows -> rows[1]["cwd"]="relative"),
        (rows -> rows[3]["id"]="u1"),
        (rows -> rows[2]["parentId"]="u1"),
        (rows -> rows[2]["parentId"]="a1"),
        (rows -> rows[3]["parentId"]="missing"),
        (rows -> rows[2]["message"]["content"]=42),
        (rows -> rows[7]["targetId"]="missing"),
    ]
        rows=deepcopy(fixture); invalid(rows)
        @test_throws ErrorException TL.parse_timeline_jsonl(jsonl(rows))
    end
end

@testset "Timeline metadata and branch transaction edge cases" begin
    fixture = timeline_oracle()["fixture"]
    make() = TL.timeline_from_rows(deepcopy(fixture))
    source = make()
    first_fork = TL.timeline_fork(source,"u1")
    @test isempty(TL.timeline_entries(first_fork.timeline))
    @test first_fork.editor_text == "U1"
    @test TL.timeline_header(first_fork.timeline)["id"] != TL.timeline_header(source)["id"]
    old_entries = TL.timeline_entries(source)
    @test_throws ErrorException TL.timeline_append_custom!(source,"bad",Dict("function"=>sin))
    @test_throws ErrorException TL.timeline_append_custom!(source,"bad",Dict("nan"=>NaN))
    @test_throws ErrorException TL.timeline_append_custom!(source,"bad",Dict("infinite"=>Inf))
    @test_throws ErrorException TL.timeline_append_message!(source,Dict("role"=>"user","content"=>"text");timestamp="2026-02-30T00:00:00Z")
    @test_throws ErrorException TL.timeline_append_message!(source,Dict("role"=>"user","content"=>"text");timestamp="not-time")
    @test TL.timeline_entries(source) == old_entries
    TL.timeline_append!(source,Dict("type"=>"future_extension_type", "opaque"=>Dict("preserved"=>[1,2]));id="future")
    @test TL.timeline_entry(source,"future")["opaque"]["preserved"] == [1,2]
    TL.timeline_append_compaction!(source,"summary","u2",12;id="compact",fields=Dict("details"=>Dict("v"=>2),"usage"=>Dict("input"=>3)))
    @test TL.timeline_entry(source,"compact")["usage"]["input"] == 3
    @test TL.timeline_entries(source)[1:length(old_entries)] == old_entries
    @test_throws ErrorException TL.timeline_append_compaction!(source,"summary","missing",12)
    @test_throws ErrorException TL.timeline_append_compaction!(source,"summary","u2",true)
    TL.timeline_branch_summary!(source,"a1","alternate summary";id="summary",fields=Dict("details"=>Dict("tag"=>"a")))
    @test [entry["id"] for entry in TL.timeline_branch(source)] == ["u1","a1","summary"]
    @test TL.timeline_entry(source,"summary")["fromId"] == "compact"
    before = TL.timeline_entries(source)
    @test_throws ErrorException TL.timeline_branch_summary!(source,"missing","bad")
    @test TL.timeline_entries(source) == before
    @test TL.timeline_leaf(source) == "summary"
    @test length(TL.timeline_messages(source)) == 2
    tree = TL.timeline_tree(source)
    @test length(tree) == 1
    @test tree[1]["label"] == "bookmark"
    @test length(tree[1]["children"][1]["children"]) == 2
    tree[1]["entry"]["message"]["content"][1]["text"]="tree mutated"
    @test TL.timeline_entry(source,"u1")["message"]["content"][1]["text"] == "U1"
    source.identity.fields["id"]="bad header mutation"
    @test TL.timeline_header(source)["id"] == source.identity.id
    labels = make()
    TL.timeline_label!(labels,"u1",nothing)
    TL.timeline_label!(labels,"u2","second")
    TL.timeline_label!(labels,"u1","first")
    clone = TL.timeline_clone(labels)
    label_rows = [entry for entry in TL.timeline_entries(clone) if entry["type"] == "label"]
    @test [entry["targetId"] for entry in label_rows] == ["u2","u1"]
    @test [entry["label"] for entry in label_rows] == ["second","first"]
    @test length(Set(entry["id"] for entry in TL.timeline_entries(clone))) == length(TL.timeline_entries(clone))
    mktempdir() do dir
        store=TL.TimelineStore(dir)
        session=make()
        path=TL.save_timeline!(store,session)
        TL.timeline_branch_summary!(session,"a1","durable summary";id="durable")
        reread=TL.load_timeline(store,session.identity.id)
        @test TL.timeline_leaf(reread)=="durable"
        @test TL.timeline_entry(reread,"durable")["summary"]=="durable summary"
        graph=TL.timeline_entries(session)
        rm(path)
        @test_throws TaskFailedException TL.timeline_name!(session,"must not resurrect deleted file")
        @test !isfile(path)
        @test TL.timeline_entries(session)==graph
        @test !ispath(path*".lock")
    end
end

@testset "Timeline concurrent writers and deep graph" begin
    mktempdir() do dir
        store=TL.TimelineStore(dir)
        original=TL.SessionTimeline(dir)
        TL.timeline_append_message!(original,Dict("role"=>"user","content"=>"start");id="root")
        TL.save_timeline!(store,original)
        first=TL.load_timeline(store,original.identity.id)
        second=TL.load_timeline(store,original.identity.id)
        jobs=[Threads.@spawn(TL.timeline_name!(source,label)) for (source,label) in [(first,"first"),(second,"second")]]
        foreach(job -> wait(job;throw=false),jobs)
        @test count(istaskfailed,jobs)==1
        restored=TL.load_timeline(store,original.identity.id)
        @test TL.timeline_name(restored) in ("first","second")
        @test length(TL.timeline_entries(restored))==2
        @test !ispath(restored.path*".lock")
    end
    timeline=TL.SessionTimeline("/tmp")
    rows=Any[TL.timeline_header(timeline)]
    for i in 1:10000
        push!(rows,Dict("type"=>"message","id"=>string(i),"parentId"=>(i==1 ? nothing : string(i-1)),
            "timestamp"=>"2026-11-01T20:00:00.000Z","message"=>Dict("role"=>"user","content"=>string(i))))
    end
    timeline=TL.timeline_from_rows(rows)
    @test length(TL.timeline_branch(timeline))==10000
    @test length(TL.timeline_tree(timeline))==1
    fork=TL.timeline_fork(timeline,"5000")
    @test length(TL.timeline_entries(fork.timeline))==4999
    @test fork.editor_text=="5000"
end

@testset "Original Pi session title and empty-boundary semantics" begin
    source=TL.SessionTimeline("/tmp")
    TL.timeline_name!(source,"  First\r\nSecond  ")
    @test TL.timeline_name(source)==timeline_oracle()["snapshots"]["names"]["normalized"]
    TL.timeline_name!(source,"   ")
    @test TL.timeline_name(source)===timeline_oracle()["snapshots"]["names"]["cleared"]
    TL.timeline_append_compaction!(source,"full summary",nothing,0;id="all")
    @test TL.timeline_entry(source,"all")["firstKeptEntryId"]=="all"
    @test_throws ErrorException TL.timeline_clone(source;id=source.identity.id)
end

@testset "Pi legacy migration and custom session identities" begin
    fixture=deepcopy(timeline_oracle()["fixture"])
    fixture[1]["id"]="safe-custom.session_1"
    timeline=TL.timeline_from_rows(fixture)
    @test TL.timeline_header(timeline)["id"]=="safe-custom.session_1"
    mktempdir() do dir
        store=TL.TimelineStore(dir)
        TL.save_timeline!(store,timeline)
        @test TL.load_timeline(store,"safe-custom.session_1").identity.id=="safe-custom.session_1"
    end
    v2=deepcopy(fixture);v2[1]["version"]=2;v2[2]["message"]["role"]="hookMessage"
    upgraded=TL.timeline_from_rows(v2)
    @test TL.timeline_entry(upgraded,"u1")["message"]["role"]=="custom"
    @test TL.timeline_header(upgraded)["version"]==3
    @test v2[1]["version"]==2
    @test v2[2]["message"]["role"]=="hookMessage"
    v1=deepcopy(fixture[1:4]);delete!(v1[1],"version")
    for entry in v1[2:end]
        delete!(entry,"id");delete!(entry,"parentId")
    end
    push!(v1,Dict("type"=>"compaction","timestamp"=>"2026-11-01T20:00:00Z","summary"=>"earlier","firstKeptEntryIndex"=>2,"tokensBefore"=>2))
    legacy=TL.timeline_from_rows(v1)
    entries=TL.timeline_entries(legacy)
    @test entries[1]["parentId"]===nothing
    @test entries[2]["parentId"]==entries[1]["id"]
    @test entries[end]["firstKeptEntryId"]==entries[2]["id"]
    @test !haskey(entries[end],"firstKeptEntryIndex")
    @test TL.timeline_header(legacy)["id"]==timeline_oracle()["snapshots"]["legacy"]["id"]
    ids=[entry["id"] for entry in entries]
    @test [isnothing(entry["parentId"]) ? nothing : findfirst(==(entry["parentId"]),ids) for entry in entries]==timeline_oracle()["snapshots"]["legacy"]["parents"]
    @test findfirst(==(entries[end]["firstKeptEntryId"]),ids)==timeline_oracle()["snapshots"]["legacy"]["firstKeptIndex"]
    @test TL.timeline_entry(legacy,entries[2]["id"])["extra"]==fixture[3]["extra"]
end

@testset "Original Pi contentless execution and context edit differential" begin
    oracle=timeline_oracle()
    expected=oracle["snapshots"]["rich"]
    timeline=TL.timeline_from_rows(oracle["fixture"])
    bash=expected["bash"]
    TL.timeline_append_message!(timeline,bash;id="bash")
    @test TL.timeline_entry(timeline,"bash")["message"]==bash
    exported=TL.parse_timeline_jsonl(TL.timeline_export_jsonl(timeline))
    @test TL.timeline_entry(exported,"bash")["message"]==bash
    TL.timeline_append_context_edit!(timeline,"a1",Dict("content"=>"Revised");id="edit")
    actual=TL.timeline_entry(timeline,"edit")
    for key in ("id","parentId","timestamp")
        delete!(actual,key)
    end
    @test actual==expected["edit"]
    @test TL.timeline_entry(timeline,"a1")["message"]==oracle["fixture"][3]["message"]
    TL.timeline_append_context_edit!(timeline,"u2",nothing;id="hide")
    actual=TL.timeline_entry(timeline,"hide")
    for key in ("id","parentId","timestamp")
        delete!(actual,key)
    end
    @test actual==expected["hide"]
    @test expected["rejectsBashEdit"]
    @test_throws ErrorException TL.timeline_append_context_edit!(timeline,"bash",Dict("content"=>"bad"))
    @test expected["rejectsBadContent"]
    @test_throws ErrorException TL.timeline_append_context_edit!(timeline,"u1",Dict("content"=>42))
    TL.timeline_branch!(timeline,"a1")
    @test expected["rejectsOffBranchEdit"]
    @test_throws ErrorException TL.timeline_append_context_edit!(timeline,"u2",nothing)
    @test_throws ErrorException TL.timeline_append_context_edit!(timeline,"missing",nothing)
    TL.timeline_append!(timeline,Dict("type"=>"custom_message","customType"=>"fixture","content"=>"C","display"=>true);id="custom")
    TL.timeline_append_context_edit!(timeline,"custom",Dict("content"=>"replacement");id="edit-custom")
    @test TL.timeline_entry(timeline,"edit-custom")["replacement"]["content"]=="replacement"
    bad=copy(bash);bad["cancelled"]="false"
    @test_throws ErrorException TL.timeline_append_message!(timeline,bad)
    @test_throws ErrorException TL.timeline_append!(timeline,Dict("type"=>"context_edit","targetId"=>"u1","replacement"=>Dict("content"=>3)))
end

@testset "Original Pi tree labels and chronological child ordering" begin
    o=timeline_oracle()
    @test TL.timeline_tree(TL.timeline_from_rows(o["fixture"]))==o["snapshots"]["tree"]["initial"]
    @test TL.timeline_tree(TL.timeline_from_rows(o["snapshots"]["tree"]["fixture"]))==o["snapshots"]["tree"]["ordered"]
    @test TL.timeline_timestamp_key("2026-11-01T20:00:00Z")==TL.timeline_timestamp_key("2026-11-01T20:00:00.000Z")
    @test TL.timeline_timestamp_key("2026-11-01T20:00:00.123456Z")==TL.timeline_timestamp_key("2026-11-01T20:00:00.123Z")
end

@testset "Native archive deletion rejects active, stale, locked and symlink targets" begin
    mktempdir() do directory
        store = TL.TimelineStore(directory)
        timeline = TL.SessionTimeline(directory)
        TL.timeline_append_message!(timeline, Dict("role" => "user", "content" => "Disposable fixture"))
        path = TL.save_timeline!(store, timeline)
        original = timeline.disk_digest
        @test_throws ErrorException TL.delete_timeline!(store, timeline.identity.id, original; active_id=timeline.identity.id)
        @test isfile(path)
        TL.timeline_name!(timeline, "Changed after listing")
        @test_throws TaskFailedException TL.delete_timeline!(store, timeline.identity.id, original)
        @test isfile(path)
        mkdir(path * ".lock")
        @test_throws Base.IOError TL.delete_timeline!(store, timeline.identity.id, timeline.disk_digest)
        rm(path * ".lock")
        copy_path = path * ".target"
        mv(path, copy_path)
        symlink(copy_path, path)
        @test_throws TaskFailedException TL.delete_timeline!(store, timeline.identity.id, timeline.disk_digest)
        @test isfile(copy_path)
        rm(path)
        mv(copy_path, path)
        @test TL.delete_timeline!(store, timeline.identity.id, timeline.disk_digest) == path
        @test !ispath(path)
        @test !ispath(path * ".lock")
    end
end

@testset "Native timestamp seconds roundtrip is timezone independent" begin
    for seconds in (-86400.0, 0.0, 951782400.123, 1793563200.456, 2147483647.999)
        @test TL.timeline_timestamp_seconds(TL.timeline_timestamp(seconds)) ≈ seconds atol=0.001
    end
    @test TL.timeline_timestamp_seconds("1970-01-01T00:00:00Z") == 0.0
    @test_throws ErrorException TL.timeline_timestamp_seconds("not a timestamp")
end
