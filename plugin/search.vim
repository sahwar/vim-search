if exists('g:loaded_search')
    finish
endif
let g:loaded_search = 1

" TODO: Vim's patch 8.1.1270 has added native support for match index after a search:{{{
"
" https://github.com/vim/vim/releases/tag/v8.1.1270
"
" You can test it like so:
"
"     $ vim -Nu NONE +'set shm-=S' ~/.zshrc
"     /the
"
" However, be aware of 2 limitations.
" You can't position the indicator on the command-line (it's at the far right).
" You can't get the index of a match beyond 99:
"
"     /pat    [1/>99]   1
"     /pat    [2/>99]   2
"     /pat    [3/>99]   3
"     ...
"     /pat    [99/>99]  99
"     /pat    [99/>99]  100
"     /pat    [99/>99]  101
"
" And be aware of 1 pitfall: the count is not always visible.
"
" In the case of `*`, you won't see it at all.
" In the  case of `n`, you  will see it, but  if you enter the  command-line and
" leave it, you won't see the count anymore when pressing `n`.
" The issue is due to Vim which does not redraw enough when `'lz'` is set.
"
" MWE:
"
"     $ vim -Nu <(cat <<'EOF'
"     set lz
"     nmap n <plug>(a)<plug>(b)
"     nno <plug>(a) n
"     nno <plug>(b) <nop>
"     EOF
"     ) ~/.zshrc
"
" Search for `the`, then press `n` a few times: the cursor does not seem to move.
" In reality,  it does  move, but  you don't see  it because  the screen  is not
" redrawn enough; press `C-l`, and you should see it has correctly moved.
"
" Solution: Make  sure that `'lz'` is  temporarily disabled when `n`,  `N`, `*`,
" `#`, `g*`, `g#`, `gd`, `gD` is pressed; or `:redraw` right after?
"
" ---
"
" If you use the builtin feature, make sure the view is always preserved.
" Last time I tried, the view was sometimes lost.
"
" For example, we have this line in this file:
"
"     nno <plug>(ms_prev) :<c-u>call search#restore_cursor_position()<cr>
"
" Position your cursor on `ms_prev`, and press `*`.
" If  the view  changes, it's  because the  next occurrence  is beyond  what the
" screen can display.
"}}}
" TODO: We don't have any mapping in visual mode for `n` and `N`.{{{
"
" So, we don't have any count when pressing `n` while in visual mode.
" Either add a mapping, or remove `S` from `'shm'`.
"}}}

" Links {{{1

" Ideas for other implementations.
"
" Interesting:
" https://github.com/neovim/neovim/issues/5581

" CACHING
"
" To improve efficiency, we cache results of last counting. This makes 'n'
" super fast. We only cache linewise counts, and in-line part is always
" recalculated. This prevents counting error from building up after multiple
" searches if in-line count was imprecise (which happens with regex searches).
"
" Source:
" https://github.com/google/vim-searchindex/blob/master/plugin/searchindex.vim

" Mappings {{{1
" Disable unwanted recursivity {{{2

" We remap the following keys RECURSIVELY:
"
"     cr
"     n N
"     * #
"     g* g#
"     gd gD
"
" Each time, we use a wrapper in the rhs.
"
" Any key returned by a wrapper will be remapped.
" We want this remapping, but only for `<plug>(…)` keys.
" For anything else, remapping should be forbidden.
" So, we install non-recursive mappings for various keys we may return in our wrappers.

cno <plug>(ms_cr)    <cr>
cno <plug>(ms_up)    <up>
nno <plug>(ms_slash) /
nno <plug>(ms_n)     n
nno <plug>(ms_N)     N
" Why don't you simply use `C-o` in the rhs?{{{
"
" It worked in the past, but not anymore.
" In Nvim, the jumplist is not updated like in Vim.
" If the cursor line doesn't change, no entry is added.
"
" We could use ``` `` ``` in Nvim and `C-o` in Vim.
" But there would still be an issue when we press `*` while visually selecting a
" unique text in the buffer.
"
" https://github.com/neovim/neovim/issues/9874
"}}}
nno <plug>(ms_prev) :<c-u>call search#restore_cursor_position()<cr>

" cr  gd  n {{{2

" NOTE:
" Don't add `<silent>` to the next mapping.
" When we search for a pattern which has no match in the current buffer,
" the combination of `set shm+=s` and `<silent>`, would make Vim display the
" search command, which would cause 2 messages to be displayed + a prompt:
"
"     /garbage
"     E486: Pattern not found: garbage
"     Press ENTER or type command to continue
"
" Without `<silent>`, Vim behaves as expected:
"     E486: Pattern not found: garbage

augroup ms_cmdwin
  au!
  au CmdWinEnter * if getcmdwintype() =~ '[/?]'
               \ |     nmap <buffer><nowait> <cr> <cr><plug>(ms_index)
               \ | endif
augroup END

" I don't think `<silent>` is needed here, but we use it to stay consistent,
" and who knows, it may be useful to sometimes avoid a brief message
nmap <expr><silent><unique> gd search#wrap_gd(1)
nmap <expr><silent><unique> gD search#wrap_gd(0)

" `<silent>` is important: it prevents `n` and `N` to display their own message
"
" without `<silent>`, when our message (`pattern [12/34]`) is displayed,
" it erases the previous one, and makes look like the command-line is flickering
nmap <expr><silent><unique> n search#wrap_n(1)
nmap <expr><silent><unique> N search#wrap_n(0)

" Star &friends {{{2

" By default,  you can search automatically  for the word under  the cursor with
" `*` or `#`. But you can't do the same for the text visually selected.
" The following mappings work  in normal mode, but also in  visual mode, to fill
" that gap.
"
" `<silent>` is useful to avoid `/ pattern cr` to display a brief message on
" the command-line.
nmap <expr><silent><unique> * search#wrap_star('*')
"                             │
"                             └ * c-o
"                               / up cr c-o
"                               <plug>(ms_nohls)
"                               <plug>(ms_view)  ⇔  <number> c-e / c-y
"                               <plug>(ms_blink)
"                               <plug>(ms_index)

nmap <expr><silent><unique> #  search#wrap_star('#')
nmap <expr><silent><unique> g* search#wrap_star('g*')
nmap <expr><silent><unique> g# search#wrap_star('g#')
" Why don't we implement `g*` and `g#` mappings?{{{
" If we search a visual selection, we probably don't want to add the anchors:
"         \< \>
"
" So our implementation of `v_*` and `v_#` don't add them.
"}}}

" FIXME: The plugin may temporarily be broken when you visually select a blockwise text.{{{
"
" As an example, select 'foo' and 'bar', and press `*`:
"
"     foo
"     bar
"     /\Vfoo\nbar~
"     E486: Pattern not found: \Vfoo\nbar~
"     Press ENTER or type command to continue~
"
" Now, search  for `foo`: the highlighting  stays active even after  we move the
" cursor (✘).
" Press `n`, then move the cursor: the highlighting is disabled (✔).
" Now, search for `foo` again: the highlighting is not enabled (✘).
"
" ---
"
" I think the issue is due to  the mapping not being processed entirely, because
" of the first error.
"
" ---
"
" For now one solution is to press `*` on a word in normal mode.
"}}}
"                     ┌ just append keys at the end to add some fancy features
"                     │                 ┌ copy visual selection
"                     │                 │┌ search for
"                     │                 ││┌ insert an expression
"                     │                 ││├─────┐
xmap <expr><unique> * search#wrap_star('y/<c-r>=search#escape(1)<plug>(ms_cr)<plug>(ms_cr)<plug>(ms_restore_unnamed_register)<plug>(ms_prev)')
"                                               ├──────────────┘│             │
"                                               │               │             └ validate search
"                                               │               └ validate expression
"                                               └ escape unnamed register

" Why?{{{
"
" I often press `g*` by accident, thinking it's necessary to avoid that Vim adds
" anchors.
" In reality, it's useless, because Vim doesn't add anchors.
" `g*` is not a default visual command.
" It's interpreted as a motion which moves the end of the visual selection to the
" next occurrence of the word below the cursor.
" This can result in a big visual selection spanning across several windows.
" Too distracting.
"}}}
xmap g* *

xmap <expr><unique> # search#wrap_star('y?<c-r>=search#escape(0)<plug>(ms_cr)<plug>(ms_cr)<plug>(ms_restore_unnamed_register)\<plug>(ms_prev)')
"                                                             │
"                                                             └ direction of the search
"                                                               necessary to know which character among [/?]
"                                                               is special, and needs to be escaped

" Customizations (blink, index, …) {{{2

nno <expr><silent> <plug>(ms_restore_unnamed_register)  search#restore_unnamed_register()

" This mapping  is used in `search#wrap_star()` to reenable  our autocmd after a
" search via star &friends.
nno <expr>         <plug>(ms_re-enable_after_slash)  search#after_slash_status('delete')

nno <expr><silent> <plug>(ms_view)  search#view()

nno <expr><silent> <plug>(ms_blink) search#blink()
nno <expr><silent> <plug>(ms_nohls) search#nohls()
nno       <silent> <plug>(ms_index) :<c-u>call search#index()<cr>
" We can't  use `<expr>` to  invoke `search#index()`,  because in the  latter we
" perform a substitution, which is forbidden when the text is locked.

" Regroup all customizations behind `<plug>(ms_custom)`
"                                      ┌ install a one-shot autocmd to disable 'hls' when we move
"                                      │               ┌ unfold if needed, restore the view after `*` &friends
"                                      │               │
nmap <silent> <plug>(ms_custom) <plug>(ms_nohls)<plug>(ms_view)<plug>(ms_blink)<plug>(ms_index)
"                                                                      │               │
"                                         make the current match blink ┘               │
"                                                      print `[12/34]` kind of message ┘

" We need this mapping for when we leave the search command-line from visual mode.
xno <expr><silent> <plug>(ms_custom) search#nohls()

" Without the next mappings, we face this issue:{{{
"
" https://github.com/junegunn/vim-slash/issues/4
"
"     c /pattern cr
"
" ... inserts a succession of literal  <plug>(…) strings in the buffer, in front
" of `pattern`.
" The problem comes from the wrong assumption that after a `/` search, we are in
" normal mode. We could also be in insert mode.
"}}}
" Why don't you disable `<plug>(ms_nohls)`?{{{
"
" Because,  the search  in `c  /pattern cr`  has enabled  'hls', so  we need  to
" disable it.
"}}}
ino <silent> <plug>(ms_nohls) <c-r>=search#nohls_on_leave()<cr>
ino <silent> <plug>(ms_index) <nop>
ino <silent> <plug>(ms_blink) <nop>
ino <silent> <plug>(ms_view)  <nop>
" }}}1
" Options {{{1

" ignore the case when searching for a pattern containing only lowercase characters
set ignorecase

" but don't ignore the case if it contains an uppercase character
set smartcase

" Incremental search
set incsearch

" Autocmds {{{1

augroup my_hls_after_slash
    au!

    " If `'hls'` and `'is'` are set, then *all* matches are highlighted when we're
    " writing a regex.  Not just the next match. See `:h 'is`.
    " So, we make sure `'hls'` is set when we enter a search command-line.
    au CmdlineEnter /,\? call search#toggle_hls('save')
    "               ├──┘
    "               └ we could also write this:     [/\?]
    "                 but it doesn't work on Windows:
    "                 https://github.com/vim/vim/pull/2198#issuecomment-341131934
    "
    "                    Also, why escape the question mark? {{{
    "                    Because, in the pattern of an autocmd, it has a special meaning:
    "
    "                            any character (:h file-pattern)
    "
    "                    We want the literal meaning, to only match a backward search command-line.
    "                    Not all the others (:h cmdwin-char).
    "
    "                    Inside a collection, it seems `?` doesn't work (no meaning).
    "                    To make some tests, use this snippet:
    "
    "                            augroup test_pattern
    "                                au!
    "                                "         ✔
    "                                               ┌ it probably works because the pattern
    "                                               │ is supposed to be a single character,
    "                                               │ so Vim interprets `?` literally, when it's alone
    "                                               │
    "                                au CmdWinEnter ?     nno <buffer> cd :echo 'hello'<cr>
    "                                au CmdWinEnter \?    nno <buffer> cd :echo 'hello'<cr>
    "                                au CmdWinEnter /,\?  nno <buffer> cd :echo 'hello'<cr>
    "                                au CmdWinEnter [/\?] nno <buffer> cd :echo 'hello'<cr>

    "                                "         ✘ (match any command-line)
    "                                au CmdWinEnter /,?   nno <buffer> cd :echo 'hello'<cr>
    "                                "         ✘ (only / is affected)
    "                                au CmdWinEnter [/?]  nno <buffer> cd :echo 'hello'<cr>
    "                            augroup END
    "}}}

    " Restore the state of `'hls'`, then invoke `after_slash()`.
    " And if the search has just failed, invoke `nohls()` to disable `'hls'`.
    au CmdlineLeave /,\? call search#toggle_hls('restore')
                     \ | if getcmdline() isnot# '' && search#after_slash_status() == 1
                     \ |     call search#after_slash(0)
                     \ |     call timer_start(0, {-> v:errmsg[:4] is# 'E486:' ? search#nohls() : ''})
                     \ | endif

    " Why `search#after_slash_status()`?{{{
    "
    " To disable this part of the autocmd when we do `/ up cr c-o`.
    "}}}
    " Why `v:errmsg...` ?{{{
    "
    " Open 2 windows with 2 buffers A and B.
    " In A, search for a pattern which has a match in B but not in A.
    " Move the cursor: the highlighting should be disabled in B, but it's not.
    " This is because Vim stops processing a mapping as soon as an error occurs:
    "
    " https://github.com/junegunn/vim-slash/issues/5
    " `:h map-error`
    "}}}
    " Why the timer?{{{
    "
    " Because we haven't performed the search yet.
    " CmdlineLeave is fired just before.
    "}}}
augroup END

augroup hoist_noic
    au!
    " Why an indicator for the 'ignorecase' option?{{{
    "
    " Recently, it  was temporarily  reset by  `$VIMRUNTIME/indent/vim.vim`, but
    " was not properly set again.
    " We should be  immediately informed when that happens,  because this option
    " has many effects;  e.g. when reset, we can't tab  complete custom commands
    " written in lowercase.
    "}}}
    au User MyFlags call statusline#hoist('global', '%2*%{!&ic? "[noic]" : ""}', 27)
    au OptionSet ignorecase call timer_start(0, {-> execute('redrawt')})
augroup END

if !has('nvim') | finish | endif

" Fixed by: https://github.com/vim/vim/releases/tag/v8.1.2338
augroup fix_E20
    au!
    " https://github.com/vim/vim/issues/3837
    " Purpose:{{{
    " Suppose we've just loaded a buffer in which the visual marks are not set anywhere.
    " We enter the command-line, and recall an old command which begins with the
    " visual range "'<,'>".
    " Because we've set the `'incsearch'` option, it will raise this error:
    "
    "     E20: Mark not set
    "
    " It's distracting.
    "}}}
    au CmdlineEnter : if !line("'<")
        \ |     call setpos("'<", [0,line('.'),col('.'),0])
        \ |     call setpos("'>", [0,line('.'),col('.'),0])
        \ | endif

    " The previous issue can be triggered by other marks.{{{
    "
    "     $ vim -Nu NONE +'set is'
    "     :'ss/p
    "
    " Every time you add a character, `E20` is raised:
    "
    "     :'ss/pa
    "     " E20
    "     :'ss/pat
    "     " E20
    "     ...
    "
    " Worse: If you press Escape to quit, the command is saved in the history.
    " So now, if you try to get back to any command which was saved earlier, you
    " will have  to visit this  buggy command which  will raise `E20`  again (at
    " least if you just press `Up` without writing any prefix).
    "
    " The  next  function   call  should  fix  this   by  temporarily  resetting
    " `'incsearch'`, and removing the buggy command from the history.
    "}}}
    au CmdlineChanged,CmdlineLeave : call s:fix_e20()
augroup END

fu s:fix_e20() abort
    if v:errmsg is# 'E20: Mark not set' && !exists('s:incsearch_save')
        let v:errmsg = ''
        let s:incsearch_save = &incsearch
        set nois
        au CmdlineLeave : ++once let &is = s:incsearch_save
            \ | unlet! s:incsearch_save
            \ | call histdel(':', histget(getcmdline()))
    endif
endfu

