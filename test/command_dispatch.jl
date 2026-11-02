module CommandDispatchTests
using Test,JSON,JuliaForever2,Tachikoma,CommonMark
const T=Base.get_extension(JuliaForever2,:JuliaForever2TerminalExt)
const JF=JuliaForever2
function fixture(blocked)
 dir=mktempdir();started=Channel{Nothing}(8);release=Channel{Nothing}(8);calls=String[]
 provider=(messages,session)->begin
  push!(calls,last(filter(message->message.role==:user,messages)).content);put!(started,nothing)
  context=JF.current_execution_context()
  if blocked
   while !isready(release)&&!JF.cancelled(context);sleep(0.001);end
   isready(release)&&take!(release)
  end
  JF.cancelled(context) ? Failure("cancelled fixture") : Answer("done")
 end
 app=T.App(Session(Kernel(provider);working_directory=dir);settings_dir=joinpath(dir,"settings"),registry=JF.ProviderRegistry(),theme_fallback="dark")
 (app,started,release,calls)
end
function drain!(app)
 timedwait(8;pollint=0.002) do
  while isready(app.queue.channel);Tachikoma.update!(app,take!(app.queue.channel));end
  !app.busy&&all(istaskdone,app.operations.watchers)
 end
end
function finish!(app,release)
 if app.busy
  JF.cancel!(app.operations.active);put!(release,nothing);drain!(app)
 end
 kernel=app.session.kernel;T.finish_shutdown!(app);close(kernel)
end
function frame(app)
 backend=TestBackend(100,24)
 render=Tachikoma.Frame(backend.buf,backend.buf.area,Tachikoma.GraphicsRegion[],Tachikoma.PixelSnapshot[])
 Tachikoma.view(app,render)
 [sprint() do io
  for x in 1:100
   cell=backend.buf.content[(y-1)*100+x]
   if cell.char != Tachikoma.WIDE_CHAR_PAD
    print(io,"\e[0m");Tachikoma.write_style(io,cell.style);print(io,Tachikoma.cell_glyph(cell))
   end
  end
  print(io,"\e[0m")
 end for y in 1:24]
end
@testset "Actual original command precedence and nonrecursive literal delivery" begin
 reference=get(ENV,"PI_REFERENCE","")
 oracle=JSON.parsefile(joinpath(@__DIR__,"../parity/fixtures/pi-command-dispatch.json"))
 if !isempty(reference)
  mktempdir() do dir
   target=joinpath(dir,"fresh.json");script=joinpath(@__DIR__,"../parity/pi_command_dispatch_oracle.mjs")
   run(addenv(`node $script $target`,"PI_SOURCE_ROOT"=>reference))
   @test JSON.parsefile(target)==oracle
  end
 end
 screens=Any[]
 for row in oracle["results"]
  config=row["config"];expected=row["trace"];app,started,release,calls=fixture(config["busy"]);extensions=String[]
  T.register_prompt!(app,"overlap","";content="WRONG template \$1")
  T.register_prompt!(app,"settings","";content="WRONG settings template")
  T.register_prompt!(app,"literal","";content="/julia error(\"literal only\")")
  T.register_command!(app,T.CommandSpec("overlap","extension",(app,args)->push!(extensions,String(args))))
  menu_before=[(command.name,command.origin) for command in T.discover_commands(app)]
  if config["busy"];T.submit!(app,"initial");take!(started);end
  Tachikoma.set_text!(app.input,config["text"])
  push!(screens,Dict("id"=>config["id"]*"/before","width"=>100,"ansiLines"=>frame(app)))
  config["action"]=="follow" ? T.follow_up_terminal_input!(app) : T.submit!(app,config["text"])
  config["busy"] || (@test drain!(app)==:ok)
  queues=JF.pending_input_snapshot(app.session)
  actual=Dict("extension"=>extensions,"submitted"=>filter(!=("initial"),calls),"steering"=>[item.message.content for item in queues.steering],"followUp"=>[item.message.content for item in queues.follow_up],"settings"=>Int(app.page==:pi_menu&&!isempty(app.menus.path)&&first(app.menus.path)=="settings"))
  push!(screens,Dict("id"=>config["id"]*"/after","width"=>100,"ansiLines"=>frame(app)))
  @test actual==expected
  @test menu_before==[(command.name,command.origin) for command in T.discover_commands(app)]
  @test count(pair->pair[1]=="overlap",menu_before)==2
  finish!(app,release)
 end
 output=get(ENV,"COMMAND_DISPATCH_SCREENS","")
 isempty(output)||write(output,JSON.json(Dict("snapshots"=>screens)))
end
end
