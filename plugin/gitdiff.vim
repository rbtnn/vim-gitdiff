command! -nargs=* GitVimDiff         :call gitdiff#vimdiff#exec(<q-args>)
command! -nargs=* GitUnifiedDiff     :call gitdiff#unifieddiff#exec(<q-args>)
command! -nargs=* GitUnifiedDiff2    :call gitdiff#unifieddiff2#exec(<q-args>)
command! -nargs=0 GitCdRootDir       :call gitdiff#cdrootdir#exec()
