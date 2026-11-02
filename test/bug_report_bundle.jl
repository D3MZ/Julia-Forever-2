using Test,JuliaForever2,JSON
const BRF=JuliaForever2
@testset "Actual private stored ZIP, consent and no overwrite" begin
 report=BRF.local_bug_report("Reproduction 日本語";provider="fixture",model="test",id="fixed",created_at="2026-11-01T00:00:00Z")
 @test !report.transcript_included && !report.summary_included
 @test first.(report.files)==["metadata.json","report.md"]
 metadata=JSON.parse(String(copy(last(first(report.files)))))
 @test !haskey(metadata,"settings") && !haskey(metadata,"credentials")
 @test metadata["application"]=="Julia Forever 2"
 @test_throws ErrorException BRF.local_bug_report("test";id="../escape")
 @test_throws ErrorException BRF.local_bug_report(repeat("x",65537))
 @test BRF.bug_report_crc(collect(codeunits("123456789")))==0xcbf43926
 dir=mktempdir();path=joinpath(dir,"bug.zip")
 exported=BRF.export_bug_report!(report,path)
 @test exported.sha256==BRF.timeline_digest(read(path))
 @test filemode(path)&0o777==0o600
 @test_throws TaskFailedException BRF.export_bug_report!(report,path)
 decoded=read(`python3 -c 'import zipfile,json,sys;z=zipfile.ZipFile(sys.argv[1]);print(json.dumps({"names":z.namelist(),"crc":z.testzip(),"text":z.read("report.md").decode()}))' $path`,String)
 data=JSON.parse(decoded)
 @test data["names"]==["metadata.json","report.md"]
 @test data["crc"]===nothing
 @test occursin("日本語",data["text"])
 selected=BRF.local_bug_report("consented";transcript="{\"type\":\"session\"}\n",summary="actual summary",id="chosen")
 @test selected.transcript_included && selected.summary_included
 @test first.(selected.files)==["metadata.json","report.md","summary.md","session.jsonl"]
 unsafe=BRF.LocalBugReport("bad","now",["../outside"=>UInt8[1]],false,false)
 @test_throws ErrorException BRF.bug_report_zip(unsafe)
end
