let s:bufvarname = 'gitdiff_scratch'

command! -nargs=* GitVimDiff :call s:git_vim_diff(<q-args>)
command! -nargs=* GitUnifiedDiff :call s:git_unified_diff(<q-args>)

function! s:git_vim_diff(q_args) abort
    let curr_ftype = &filetype
    let rev = empty(a:q_args) ? 'HEAD' : a:q_args

    let rootdir = s:git_get_rootdir()
    if !s:check_git(rootdir)
        return
    endif

    let relpath = s:get_current_relpath(rootdir)
    if empty(relpath)
        return s:error('The current buffer is not managed by git repository')
    endif

    let diff_lines = s:git_system(rootdir, ['diff', '--numstat', rev])
    if 0 == len(filter(diff_lines, { i, x -> x =~# '^\d\+\t\d\+\t' .. relpath .. '$' }))
        return s:error('There are no differences')
    endif

    let show_lines = s:git_system(rootdir, ['show', rev .. ':' .. relpath])
    if get(show_lines, 0, '') =~# '^fatal: '
        return s:error(join(show_lines, "\n"))
    endif

    call s:close_diff_scratches()

    diffthis
    vnew
    let b:[(s:bufvarname)] = 1
    setlocal modifiable noreadonly
    call setbufline(bufnr(), 1, show_lines)
    setlocal buftype=nofile nomodifiable readonly
    let &l:filetype = curr_ftype
    diffthis
endfunction

function! s:git_unified_diff(q_args) abort
    let rootdir = s:git_get_rootdir()
    if !s:check_git(rootdir)
        return
    endif

    let lines = s:git_system(rootdir, ['diff', '--numstat', '-w'] + split(a:q_args, '\s\+'))
    if empty(lines)
        call s:error('No modified files!')
    else
        new
        setlocal modifiable noreadonly
        call setbufline(bufnr(), 1, lines)
        setlocal buftype=nofile nomodifiable readonly nolist
        execute printf('nnoremap <buffer><cr>    <Cmd>call <SID>show_diff(%s,%s)<cr>', string(a:q_args), string(rootdir))
    endif
endfunction

function! s:show_diff(q_args, rootdir) abort
    let path = s:fix_path(expand(a:rootdir .. '/' .. trim(get(split(getline('.'), "\t") ,2, ''))))
    if filereadable(path)
        let wnr = winnr()
        let lnum = line('.')

        let exists = v:false
        for w in filter(getwininfo(), { _, x -> x['tabnr'] == tabpagenr() })
            if getbufvar(w['bufnr'], '&filetype', '') == 'diff'
                execute printf('%dwincmd w', w['winnr'])
                let exists = v:true
                break
            endif
        endfor
        if !exists
            if &lines < &columns / 2
                botright vnew
            else
                botright new
            endif
            setfiletype diff
            setlocal nolist
        endif

        let lines = s:git_system(a:rootdir, ['--no-pager', 'diff', '-w'] + split(a:q_args, '\s\+') + ['--', path])
        setlocal modifiable noreadonly
        silent! call deletebufline(bufnr(), 1, '$')
        call setbufline(bufnr(), 1, lines)
        setlocal buftype=nofile nomodifiable readonly

        execute printf('nnoremap <buffer><cr>  <Cmd>call <SID>jump_diffline(%s)<cr>', string(a:rootdir))
    endif
endfunction

function! s:jump_diffline(rootdir) abort
    let x = s:calc_lnum(a:rootdir)
    if !empty(x)
        if filereadable(x['path'])
            if s:find_window_by_path(x['path'])
                execute printf(':%d', x['lnum'])
            else
                new
                call s:open_file(x['path'], x['lnum'])
            endif
        endif
        normal! zz
    endif
endfunction

function! s:find_window_by_path(path) abort
    for x in filter(getwininfo(), { _, x -> x['tabnr'] == tabpagenr() })
        if x['bufnr'] == s:strict_bufnr(a:path)
            execute printf(':%dwincmd w', x['winnr'])
            return v:true
        endif
    endfor
    return v:false
endfunction

function! s:can_open_in_current() abort
    let tstatus = term_getstatus(bufnr())
    if (tstatus != 'finished') && !empty(tstatus)
        return v:false
    elseif !empty(getcmdwintype())
        return v:false
    elseif &modified
        return v:false
    else
        return v:true
    endif
endfunction

function! s:strict_bufnr(path) abort
    let bnr = bufnr(a:path)
    let fname1 = fnamemodify(a:path, ':t')
    let fname2 = fnamemodify(bufname(bnr), ':t')
    if (-1 == bnr) || (fname1 != fname2)
        return -1
    else
        return bnr
    endif
endfunction

function! s:calc_lnum(rootdir) abort
    let lines = getbufline(bufnr(), 1, '$')
    let curr_lnum = line('.')
    let lnum = -1
    let relpath = ''

    for m in range(curr_lnum, 1, -1)
        if lines[m - 1] =~# '^@@'
            let lnum = m
            break
        endif
    endfor
    for m in range(curr_lnum, 1, -1)
        if lines[m - 1] =~# '^+++ '
            let relpath = matchstr(lines[m - 1], '^+++ \zs.\+$')
            let relpath = substitute(relpath, '^b/', '', '')
            let relpath = substitute(relpath, '\s\+(working copy)$', '', '')
            let relpath = substitute(relpath, '\s\+(revision \d\+)$', '', '')
            break
        endif
    endfor

    if (lnum < curr_lnum) && (0 < lnum)
        let n1 = 0
        let n2 = 0
        for n in range(lnum + 1, curr_lnum)
            let line = lines[n - 1]
            if line =~# '^-'
                let n2 += 1
            elseif line =~# '^+'
                let n1 += 1
            endif
        endfor
        let n3 = curr_lnum - lnum - n1 - n2 - 1
        let m = []
        let m2 = matchlist(lines[lnum - 1], '^@@ \([+-]\)\(\d\+\)\%(,\d\+\)\? \([+-]\)\(\d\+\)\%(,\d\+\)\?\s*@@\(.*\)$')
        let m3 = matchlist(lines[lnum - 1], '^@@@ \([+-]\)\(\d\+\)\%(,\d\+\)\? \([+-]\)\(\d\+\)\%(,\d\+\)\? \([+-]\)\(\d\+\),\d\+\s*@@@\(.*\)$')
        if !empty(m2)
            let m = m2
        elseif !empty(m3)
            let m = m3
        endif
        if !empty(m)
            for i in [1, 3, 5]
                if '+' == m[i]
                    let lnum = str2nr(m[i + 1]) + n1 + n3
                    return { 'lnum': lnum, 'path': expand(a:rootdir .. '/' .. relpath) }
                endif
            endfor
        endif
    endif

    return {}
endfunction

function! s:open_file(path, lnum) abort
    const ok = s:can_open_in_current()
    let bnr = s:strict_bufnr(a:path)
    if bufnr() == bnr
    " nop if current buffer is the same
    elseif ok
        if -1 == bnr
            execute printf('edit %s', fnameescape(a:path))
        else
            silent! execute printf('buffer %d', bnr)
        endif
    else
        execute printf('new %s', fnameescape(a:path))
    endif
    if 0 < a:lnum
        call cursor([a:lnum, 1])
    endif
endfunction

function! s:check_git(rootdir) abort
    if !executable('git')
        call s:error('Git command is not executable')
        return v:false
    endif

    if !isdirectory(a:rootdir)
        call s:error('The current directory is not under git control')
        return v:false
    endif

    return v:true
endfunction

function! s:get_current_relpath(rootdir) abort
    let fullpath = expand("%:p")
    if filereadable(fullpath)
        for path in s:git_system(a:rootdir, ['ls-files'])
            if s:fix_path(expand(a:rootdir .. '/' .. path)) == s:fix_path(fullpath)
                return path
            endif
        endfor
    endif
    return ''
endfunction

function! s:fix_path(path) abort
    return substitute(a:path, '[\/]', '/', 'g')
endfunction

function! s:error(msg) abort
    echohl Error
    echo printf('[gitdiff] %s!', a:msg)
    echohl None
endfunction

function! s:close_diff_scratches() abort
    for w in filter(getwininfo(), { _, x -> x['tabnr'] == tabpagenr() })
        if &diff
            call win_execute(w['winid'], 'diffoff')
        endif
        if getbufvar(w['bufnr'], s:bufvarname, 0)
            call win_execute(w['winid'], 'close')
        endif
    endfor
endfunction

function! s:git_get_rootdir(path = '.') abort
    let xs = split(fnamemodify(a:path, ':p'), '[\/]')
    let prefix = (has('mac') || has('linux')) ? '/' : ''
    while !empty(xs)
        let path = prefix .. join(xs + ['.git'], '/')
        if isdirectory(path) || filereadable(path)
            return prefix .. join(xs, '/')
        endif
        call remove(xs, -1)
    endwhile
    return ''
endfunction

function s:git_system(cwd, subcmd) abort
    let cmd_prefix = ['git', '--no-pager']
    if has('nvim')
        let params = [{ 'lines': [], }]
        let job = jobstart(cmd_prefix + a:subcmd, {
            \ 'cwd': a:cwd,
            \ 'on_stdout': function('s:nvim_event', params),
            \ })
        call jobwait([job])
        return params[0]['lines']
    else
        let lines = []
        let path = tempname()
        try
            let job = job_start(cmd_prefix + a:subcmd, {
                \ 'cwd': a:cwd,
                \ 'out_io': 'file',
                \ 'out_name': path,
                \ 'err_io': 'out',
                \ })
            while 'run' == job_status(job)
            endwhile
            if filereadable(path)
                let lines = readfile(path)
            endif
        finally
            if filereadable(path)
                call delete(path)
            endif
        endtry
        return lines
    endif
endfunction

function s:nvim_event(...) abort
    let a:000[0]['lines'] += a:000[2]
    sleep 10m
endfunction

