@echo off
setlocal

set "ROOT=%~dp0"
set "STUDIO_STUD_EXE=%ROOT%.studio-stud-tool\bin\studio-stud.exe"

if not exist "%STUDIO_STUD_EXE%" (
    echo Studio Stud executable not found: "%STUDIO_STUD_EXE%" 1>&2
    echo Reinstall with: irm https://tyleradams2002.github.io/studio-stud/install.ps1 ^| iex 1>&2
    exit /b 1
)

pushd "%ROOT%" >nul
"%STUDIO_STUD_EXE%" %*
set "STUDIO_STUD_EXIT=%ERRORLEVEL%"
popd >nul

exit /b %STUDIO_STUD_EXIT%
