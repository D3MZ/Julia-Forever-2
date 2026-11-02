using Test,JuliaForever2,Tachikoma,CommonMark,JSON,SHA
isdefined(@__MODULE__,:TerminalCellFixture) || include("differential/terminal_cell_fixture.jl")
isdefined(@__MODULE__,:AuthenticationFixture) || include("differential/authentication_fixture.jl")
isdefined(Main,:AuthHost) || include("authentication_menu_controls.jl")
@eval AuthHost begin
    const copy_terminal_text! = Owner.copy_terminal_text!
    include(joinpath(@__DIR__,"..","ext","terminal","authentication_dialog_controls.jl"))
end
function auth_dialog_actual_buffer(lines,width)
    buffer=Tachikoma.Buffer(Tachikoma.Rect(1,1,width,length(lines)))
    AuthHost.Owner.draw_menu_lines!(buffer,1,1,width,lines)
    buffer
end
function auth_dialog_buffer(lines,width)
    buffer=auth_dialog_actual_buffer(lines,width)
    [sprint() do io
        for column in 1:width
            cell=buffer.content[(row-1)*width+column]
            if cell.char!='\0'
                Tachikoma.write_style(io,cell.style)
                isempty(cell.style.hyperlink) || print(io,"\e]8;;",cell.style.hyperlink,"\e\\")
                print(io,Tachikoma.cell_glyph(cell))
                isempty(cell.style.hyperlink) || print(io,"\e]8;;\e\\")
            end
        end
        print(io,"\e[0m")
    end for row in eachindex(lines)]
end
@testset "Full native authentication dialog uses original geometry and private callback input" begin
 reference=get(ENV,"PI_REFERENCE","")
 @test isempty(reference) || isdir(reference)
 begin
  mktempdir() do temp
   output=joinpath(temp,"reference.json")
   oracle=joinpath(@__DIR__,"differential","pi_auth_dialog_oracle.mjs")
   provenance=joinpath(@__DIR__,"fixtures","pi-menu-search-provenance.json")
   original,cell_fixture=AuthenticationFixture.load(:dialog,reference,output)
   evidence=get(ENV,"AUTH_DIALOG_EVIDENCE",temp);mkpath(evidence)
   cp(output,joinpath(evidence,"reference-full.json");force=true)
   native=[];expected=[];projected=[];states=[];raw_matches=0
   for case in original["cases"]
    mktempdir() do directory
     app=AuthHost.Owner.App(;settings_dir=directory)
     catalog=AuthHost.Owner.theme_catalog("";preserve_extras=false)
     catalog.bold=original["capabilities"]["bold"]
     app.menus.theme_runtime=AuthHost.Owner.ThemeRuntime(catalog;setting=case["theme"])
     available=Ref(false)
     starter=(app,id;action)->begin
      app.settings.auth_flow=JuliaForever2.AuthFlow();app.settings.auth_provider=id
      app.page=:auth;app.busy=true;app.status="Opening browser for sign-in…";nothing
     end
     submit=(flow,value)->(ok=true,reason="synthetic intake only")
     control=AuthHost.auth_menu_open!(app,"login";on_login=starter,on_manual_available=flow->available[],on_manual_submit=submit)
     AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
     AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
     for (index,stage) in enumerate([Dict("op"=>"open","after"=>case["initial"]);case["transitions"]])
      op=stage["op"]
      if op=="url"
       app.settings.auth_url=case["url"]
      elseif op=="manual"
       available[]=true
      elseif op=="input"
       raw=Vector{UInt8}(codeunits(stage["data"]))
       AuthHost.auth_dialog_input!(app,control,Tachikoma.KeyEvent(:char,'x'),raw)
      end
      frame=AuthHost.auth_dialog_layout(app,control,case["width"])
      id=case["theme"]*"."*case["id"]*"."*string(index)
      @test length(frame.lines)==length(stage["after"]["privacyProjectedAnsiLines"])
      expected_cursor=stage["after"]["cursor"]
      if isnothing(expected_cursor)
       @test isnothing(frame.cursor)
      else
       @test frame.cursor==(x=expected_cursor["col"],y=expected_cursor["row"])
      end
      @test control.callback_input.received==any(event->get(event,"kind","")=="intake",stage["after"]["state"]["callbacks"])
      buffer=auth_dialog_actual_buffer(frame.lines,case["width"])
      raw_matches+=isempty(TerminalCellFixture.differences(buffer,cell_fixture,id,case["width"]))
      @test isempty(TerminalCellFixture.differences(buffer,cell_fixture,id*".private",case["width"]))
      push!(native,(id,width=case["width"],ansiLines=auth_dialog_buffer(frame.lines,case["width"]),event=stage["op"]))
      push!(expected,(id,width=case["width"],terminalAnsiLines=stage["after"]["terminalAnsiLines"],event=stage["op"]))
      push!(projected,(id,width=case["width"],terminalAnsiLines=stage["after"]["privacyProjectedAnsiLines"],event=stage["op"]))
      push!(states,(id,width=case["width"],cursor=frame.cursor,received=control.callback_input.received,status=app.status))
      @test !occursin("SYNTHETIC_ONLY",repr(control.callback_input))
      if index>=4
       text=join(join(span.content for span in row) for row in frame.lines)
       @test !occursin("client_id=SYNTHETIC_ONLY",text)
      end
     end
     close(control.flow);close(app.session)
    end
   end
   write(joinpath(evidence,"native-buffer.json"),JSON.json((snapshots=native,)))
   write(joinpath(evidence,"reference.json"),JSON.json((snapshots=expected,)))
   write(joinpath(evidence,"states.json"),JSON.json(states))
   @test raw_matches==24
   @test length(native)==48
   write(joinpath(evidence,"privacy-projected-reference.json"),JSON.json((snapshots=projected,)))
   if isdir(reference)
   comparator=joinpath(@__DIR__,"..","parity","compare_terminal_cells.mjs")
   rp,np,cpth=(joinpath(evidence,n) for n in ("reference.json","native-buffer.json","cells.json"))
   run(pipeline(`node $comparator $rp $np $cpth`;stdout=devnull))
   result=JSON.parsefile(cpth)
   println("Auth full dialog raw frames: ",result["matching"],"/",result["checked"],"; masked-entry differences must remain explicit.")
   @test result["matching"]==24
   privacy_path=joinpath(evidence,"privacy-projected-reference.json")
   privacy_cells=joinpath(evidence,"privacy-projected-cells.json")
   write(privacy_path,JSON.json((snapshots=projected,)))
   run(pipeline(`node $comparator $privacy_path $np $privacy_cells`;stdout=devnull))
   privacy=JSON.parsefile(privacy_cells)
   println("Auth dialog with explicit privacy-only projection: ",privacy["matching"],"/",privacy["checked"])
   @test privacy["matching"]==48
   end
  end
 end
end

@testset "Native auth copy and cancel act on the current owner only" begin
 mktempdir() do directory
  app=AuthHost.Owner.App(;settings_dir=directory)
  starter=(app,id;action)->begin
   app.settings.auth_flow=JuliaForever2.AuthFlow();app.settings.auth_provider=id
   app.page=:auth;app.busy=true;app.status="Opening browser for sign-in…";nothing
  end
  control=AuthHost.auth_menu_open!(app,"login";on_login=starter,on_manual_available=Returns(false),on_manual_submit=Returns((ok=false,reason="not called")))
  AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
  AuthHost.auth_menu_input!(app,control,Tachikoma.KeyEvent(:enter))
  app.settings.auth_url="https://auth.example.invalid/authorize?state=SYNTHETIC"
  copied=String[]
  copier=(app,value)->begin;push!(copied,value);app.status="Copied to clipboard";true;end
  @test AuthHost.auth_dialog_input!(app,control,Tachikoma.KeyEvent(:ctrl,'x');copy=copier)
  @test copied==[app.settings.auth_url]
  @test occursin("Copied URL",join(join(s.content for s in row) for row in AuthHost.auth_dialog_layout(app,control,80).lines))
  @test !AuthHost.auth_dialog_copy!(app,control)
  @test app.status=="No supported clipboard destination"
  app.settings.auth_url="file:///synthetic"
  @test !AuthHost.auth_dialog_copy!(app,control;copy=copier)
  @test length(copied)==1
  app.settings.auth_url="https://auth.example.invalid/\e[31m"
  @test isempty(AuthHost.auth_dialog_url(app))
  @test AuthHost.auth_dialog_input!(app,control,Tachikoma.KeyEvent(:ctrl_c))
  @test !JuliaForever2.active_auth(control.flow)
  @test app.page==:auth && app.busy
  app.menus.generation+=UInt(1)
  @test !AuthHost.auth_dialog_input!(app,control,Tachikoma.KeyEvent(:enter))
  @test isempty(AuthHost.auth_dialog_layout(app,control,80).lines)
  close(control.flow);close(app.session)
 end
end
