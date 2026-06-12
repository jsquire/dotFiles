svn cleanup .
svn revert -R .
For /f "tokens=1,2" %%A in ('svn status --no-ignore') Do (
     If [%%A]==[?] ( Call :UniDelete %%B
     ) Else If [%%A]==[I] Call :UniDelete %%B
   )
svn update .
goto :eof

:UniDelete delete file/dir
IF EXIST "%1\*" (
    RD /S /Q "%1"
) Else (
    If EXIST "%1" DEL /S /F /Q "%1"
)
goto :eof