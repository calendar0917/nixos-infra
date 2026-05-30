# =============================================================================
# 环境变量 (Environment Variables)
# =============================================================================

# 路径设置
# 添加 npm 全局包路径
fish_add_path $HOME/.npm-global/bin
fish_add_path $HOME/.cargo/bin
fish_add_path $HOME/go/bin
# fnm 初始化
fnm env --use-on-cd --shell fish | source
# pnpm
set -gx PNPM_HOME "/home/calendar/.local/share/pnpm"
if not string match -q -- $PNPM_HOME $PATH
    set -gx PATH "$PNPM_HOME" $PATH
end

# Java 环境设置
set -gx JAVA_TOOL_OPTIONS "-Dsun.java2d.uiScale=2.0 -Dsun.java2d.dpiaware=false"
set -g GTK_CSD 0

# Cargo 路径配置
if test -d $HOME/.cargo/bin
    set -gx PATH $HOME/.cargo/bin $PATH
end

# 路径跳转
zoxide init fish | source

# vim 模式
#set -g fish_key_bindings fish_vi_key_bindings
# 设置 vi 模式下的光标形状
#set fish_cursor_default block # Normal 模式：方块
#set fish_cursor_insert line # Insert 模式：竖线
#set fish_cursor_replace_one underscore # 替换模式：下划线
#set fish_cursor_visual block # Visual 模式：方块

# =============================================================================
# 别名设置 (Aliases)
# =============================================================================

# 代理设置
# 开启代理函数
function pon
    set -gx http_proxy http://127.0.0.1:7897
    set -gx https_proxy http://127.0.0.1:7897
    set -gx all_proxy socks5://127.0.0.1:7897
    echo 终端代理已开启
end

# 关闭代理函数
function poff
    set -e http_proxy
    set -e https_proxy
    set -e all_proxy
    echo 终端代理已关闭
end
# 路径跳转
alias cdot='cd ~/dotfiles/'
alias cc='cd ~/code'
alias cdon='cd ~/Downloads/'
alias ccon='cd ~/Documents/quartz/content'
alias ch='cd ~'
# pacman
alias psyu='sudo pacman -Syu'
# 快速开启应用
alias n='nvim'
alias bt='btop'

# AI 工具设置 (AIChat)
alias ask="aichat -m deepseek:deepseek-chat -- --stram true --role assistant -e"
alias chat="aichat -m deepseek:deepseek-chat --role assistant"
alias think="aichat -m deepseek:deepseek-reasoner"

abbr -a ttui taskwarrior-tui
abbr -a ydon 'y ~/Downloads'
abbr -a yconf 'y ~/.config'
abbr -a ypro 'y ~/Project'
abbr -a yc 'y ~/Project/code/'
abbr -a ycon 'y ~/Project/quartz/content'
abbr -a ga 'git add .'
abbr -a gm 'git commit -m'
abbr -a gp 'git push'

if status is-interactive
    # 禁用 Fish 默认的问候语
    set -g fish_greeting ""
end

function y
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    yazi $argv --cwd-file="$tmp"
    if set cwd (command cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
        builtin cd -- "$cwd"
    end
    rm -f -- "$tmp"
end

# >>> mamba initialize >>>
# !! Contents within this block are managed by 'mamba shell init' !!
set -gx MAMBA_EXE /home/calendar/miniforge3/bin/mamba
set -gx MAMBA_ROOT_PREFIX /home/calendar/miniforge3
$MAMBA_EXE shell hook --shell fish --root-prefix $MAMBA_ROOT_PREFIX | source
# <<< mamba initialize <<<
