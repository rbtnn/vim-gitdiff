let s:bufvarname = 'gitdiff_scratch'
let s:special_buffer = 'gitdiff_special_buffer'

command! -nargs=* GitVimDiff     :call s:git_vim_diff(<q-args>)
command! -nargs=* GitUnifiedDiff :call s:git_unified_diff(<q-args>)
command! -nargs=0 GitCdRootDir   :call s:git_cd_rootdir()

function! s:git_vim_diff(q_args) abort
    let curr_ftype = &filetype
    let rev = empty(a:q_args) ? 'HEAD' : a:q_args

    let rootdir = s:git_get_rootdir()
    if !s:check_git(rootdir)
        return
    endif

    let relpath = s:get_current_relpath(rootdir)
    if empty(relpath)
        return s:echo_error('The current buffer is not managed by git repository')
    endif

    let diff_lines = s:git_system(rootdir, ['diff', '--numstat', rev])
    if 0 == len(filter(diff_lines, { i, x -> x =~# '^\d\+\t\d\+\t' .. relpath .. '$' }))
        return s:echo_error('There are no differences')
    endif

    let show_lines = s:git_system(rootdir, ['show', rev .. ':' .. relpath])
    if get(show_lines, 0, '') =~# '^fatal: '
        return s:echo_error(join(show_lines, "\n"))
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

    let lines = s:git_system(rootdir, ['diff', '--numstat'] + split(a:q_args, '\s\+'))
    call s:open_special_buffer('numstat', lines)
    if empty(lines)
        call s:echo_error('No modified files!')
    else
        execute printf('nnoremap <buffer><cr>    <Cmd>call <SID>show_diff(%s,%s)<cr>', string(a:q_args), string(rootdir))
        execute printf('nnoremap <buffer>!       <Cmd>call <SID>git_unified_diff(%s)<cr>', string(a:q_args))
    endif
endfunction

function! s:git_cd_rootdir() abort
    let rootdir = s:git_get_rootdir()
    if !empty(rootdir)
        if !empty(chdir(rootdir))
            call s:echo_message('Changed to git rootdir:')
            verbose pwd
            return
        endif
    endif
    call s:echo_error('Could not find a git rootdir!')
endfunction

function! s:open_special_buffer(btype, lines) abort
    let wnr = winnr()
    let lnum = line('.')

    let exists = v:false
    for w in filter(getwininfo(), { _, x -> x['tabnr'] == tabpagenr() })
        if getbufvar(w['bufnr'], s:special_buffer, 0)
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
    endif

    call setbufvar(bufnr(), s:special_buffer, 1)
    setlocal nolist
    execute 'setfiletype ' .. a:btype

    if empty(a:lines)
        close
    else
        setlocal modifiable noreadonly
        silent! call deletebufline(bufnr(), 1, '$')
        call setbufline(bufnr(), 1, a:lines)
        setlocal buftype=nofile nomodifiable readonly
    endif
endfunction

function! s:show_diff(q_args, rootdir) abort
    let path = trim(get(split(getline('.'), "\t") ,2, ''))
    call s:show_diff_with_path(a:q_args, a:rootdir, path)
endfunction

function! s:show_diff_with_path(q_args, rootdir, path) abort
    let path = s:fix_path(expand(a:rootdir .. '/' .. a:path))
    if filereadable(path)
        let lines = s:git_system(a:rootdir, ['--no-pager', 'diff'] + split(a:q_args, '\s\+') + ['--', path])
        call s:open_special_buffer('diff', lines)
        if !empty(lines)
            execute printf('nnoremap <buffer><cr>  <Cmd>call <SID>jump_diffline(%s)<cr>', string(a:rootdir))
            execute printf('nnoremap <buffer>!     <Cmd>call <SID>show_diff_with_path(%s,%s,%s)<cr>', string(a:q_args), string(a:rootdir), string(a:path))
        endif
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
        call s:echo_error('Git command is not executable')
        return v:false
    endif

    if !isdirectory(a:rootdir)
        call s:echo_error('The current directory is not under git control')
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

function! s:echo_error(msg) abort
    echohl Error
    echo printf('[gitdiff] %s!', a:msg)
    echohl None
endfunction

function! s:echo_message(msg) abort
    echohl Title
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

