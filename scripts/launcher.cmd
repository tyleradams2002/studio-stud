@echo off
setlocal

set "ROOT=%~dp0"
set "CANONICAL=%LOCALAPPDATA%\Programs\StudioStud\bin\studio-stud.exe"
set "LEGACY=%ROOT%.studio-stud-tool\bin\studio-stud.exe"

if exist "%CANONICAL%" (
    set "STUDIO_STUD_EXE=%CANONICAL%"
) else if exist "%LEGACY%" (
    set "STUDIO_STUD_EXE=%LEGACY%"
) else (
    echo studio-stud daemon not found at "%CANONICAL%" or "%LEGACY%" 1>&2
    echo Reinstall: irm https://tyleradams2002.github.io/studio-stud/install.ps1 ^| iex 1>&2
    exit /b 1
)

pushd "%ROOT%" >nul
"%STUDIO_STUD_EXE%" %*
set "STUDIO_STUD_EXIT=%ERRORLEVEL%"
popd >nul

exit /b %STUDIO_STUD_EXIT%
