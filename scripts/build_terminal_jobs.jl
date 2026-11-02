using Libdl,SHA,JSON
Sys.islinux() || error("The native terminal job-control adapter currently requires Linux GNU libc")
compiler=get(ENV,"CC","cc")
source=normpath(joinpath(@__DIR__,"..","deps","native","terminal_jobs.c"))
directory=isempty(ARGS) ? normpath(joinpath(@__DIR__,"..","deps","usr","lib")) : abspath(only(ARGS))
mkpath(directory)
library=joinpath(directory,"libjf2_terminal_jobs."*Libdl.dlext)
mktempdir(directory) do temporary
    staged=joinpath(temporary,basename(library))
    run(`$compiler -std=c11 -Wall -Wextra -Werror -O2 -shared -fPIC -pthread $source -o $staged`)
    version=readchomp(`$compiler --version`)
    write(staged*".json",JSON.json(Dict("abi"=>"1.0.0","source_sha256"=>bytes2hex(sha256(read(source))),"library_sha256"=>bytes2hex(sha256(read(staged))),"compiler"=>version))*"\n")
    mv(staged,library;force=true)
    mv(staged*".json",library*".json";force=true)
end
println("Built native terminal job-control adapter: ",library)
