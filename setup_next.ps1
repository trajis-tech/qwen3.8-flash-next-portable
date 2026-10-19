# Download everything (source, portable Python, engine, model) without starting the server.
# Same parameters as start_next.ps1; e.g.  .\setup_next.ps1 -Family qwen-nvfp4-gptq
& "$PSScriptRoot\start_next.ps1" -SetupOnly @args
exit $LASTEXITCODE
