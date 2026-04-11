let g:loaded_gitdiff = 1

command! -nargs=* GitUnifiedDiff     :call gitdiff#unifieddiff#exec(<q-args>)
if get(g:, 'gitdiff_optional', v:false)
  command! -nargs=* GitVimDiff         :call gitdiff#vimdiff#exec(<q-args>)
  command! -nargs=0 GitCdRootDir       :call gitdiff#cdrootdir#exec()
  command! -nargs=1 GitGrep            :call gitdiff#grep#exec(<q-args>)
endif
