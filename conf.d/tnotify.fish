# MIT License

# Copyright (c) 2016 Francisco Lourenço & Daniel Wehner

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

if not status is-interactive
    exit
end

set -g __tnotify_version 1.19.3

function __tnotify_run_powershell_script
    set -l powershell_exe (command --search "powershell.exe")

    if test $status -ne 0
        and command --search wslvar

        set -l powershell_exe (wslpath (wslvar windir)/System32/WindowsPowerShell/v1.0/powershell.exe)
    end

    if string length --quiet "$powershell_exe"
        and test -x "$powershell_exe"

        set cmd (string escape $argv)

        eval "$powershell_exe -Command $cmd"
    end
end

function __tnotify_windows_notification -a title -a message
    if test "$__tnotify_notify_sound" -eq 1
        set soundopt "<audio silent=\"false\" src=\"ms-winsoundevent:Notification.Default\" />"
    else
        set soundopt "<audio silent=\"true\" />"
    end

    __tnotify_run_powershell_script "
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null

\$toast_xml_source = @\"
    <toast>
        $soundopt
        <visual>
            <binding template=\"ToastText02\">
                <text id=\"1\">$title</text>
                <text id=\"2\">$message</text>
            </binding>
        </visual>
    </toast>
\"@

\$toast_xml = New-Object Windows.Data.Xml.Dom.XmlDocument
\$toast_xml.loadXml(\$toast_xml_source)

\$toast = New-Object Windows.UI.Notifications.ToastNotification \$toast_xml

[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(\"fish\").Show(\$toast)
"
end

function __tnotify_get_focused_window_id
    if type -q lsappinfo
        lsappinfo info -only bundleID (lsappinfo front | string replace 'ASN:0x0-' '0x') | cut -d '"' -f4
    else if test -n "$SWAYSOCK"
        and type -q jq
        swaymsg --type get_tree | jq '.. | objects | select(.focused == true) | .id'
    else if test -n "$HYPRLAND_INSTANCE_SIGNATURE"
        hyprctl activewindow | awk 'NR==1 {print $2}'
    else if begin
            test "$XDG_SESSION_DESKTOP" = gnome; and type -q gdbus
        end
        gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell --method org.gnome.Shell.Eval 'global.display.focus_window.get_id()'
    else if type -q xprop
        and test -n "$DISPLAY"
        # Test that the X server at $DISPLAY is running
        and xprop -grammar >/dev/null 2>&1
        xprop -root 32x '\t$0' _NET_ACTIVE_WINDOW | cut -f 2
    else if uname -a | string match --quiet --ignore-case --regex microsoft
        __tnotify_run_powershell_script '
Add-Type @"
    using System;
    using System.Runtime.InteropServices;
    public class WindowsCompat {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }
"@
[WindowsCompat]::GetForegroundWindow()
'
    else if set -q __tnotify_allow_nongraphical
        echo 12345 # dummy value
    end
end

function __tnotify_is_tmux_window_active
    set -q fish_pid; or set -l fish_pid %self

    # find the outermost process within tmux
    # ppid != "tmux" -> pid = ppid
    # ppid == "tmux" -> break
    set tmux_fish_pid $fish_pid
    while set tmux_fish_ppid (ps -o ppid= -p $tmux_fish_pid | string trim)
        # remove leading hyphen so that basename does not treat it as an argument (e.g. -fish), and return only
        # the actual command and not its arguments so that basename finds the correct command name.
        # (e.g. '/usr/bin/tmux' from command '/usr/bin/tmux new-session -c /some/start/dir')
        and ! string match -q "tmux*" (basename (ps -o command= -p $tmux_fish_ppid | string replace -r '^-' '' | string split ' ')[1])
        set tmux_fish_pid $tmux_fish_ppid
    end

    # tmux session attached and window is active -> no notification
    # all other combinations -> send notification
    tmux list-panes -a -F "#{session_attached} #{window_active} #{pane_pid}" | string match -q "1 1 $tmux_fish_pid"
end

function __tnotify_is_screen_window_active
    string match --quiet --regex "$STY\s+\(Attached" (screen -ls)
end

function __tnotify_is_process_window_focused
    # Return false if the window is not focused

    if set -q __tnotify_allow_nongraphical
        return 1
    end

    if set -q __tnotify_kitty_remote_control
        kitty @ --password="$__tnotify_kitty_remote_control_password" ls | jq -e ".[].tabs[] | select(any(.windows[]; .is_self)) | .is_focused" >/dev/null
        return $status
    end

    set __tnotify_focused_window_id (__tnotify_get_focused_window_id)
    if test "$__tnotify_sway_ignore_visible" -eq 1
        and test -n "$SWAYSOCK"
        string match --quiet --regex "^true" (swaymsg -t get_tree | jq ".. | objects | select(.id == "$__tnotify_initial_window_id") | .visible")
        return $status
    else if test -n "$HYPRLAND_INSTANCE_SIGNATURE"
        and test $__tnotify_initial_window_id = (hyprctl activewindow | awk 'NR==1 {print $2}')
        return $status
    else if test "$__tnotify_initial_window_id" != "$__tnotify_focused_window_id"
        return 1
    end
    # If inside a tmux session, check if the tmux window is focused
    if type -q tmux
        and test -n "$TMUX"
        __tnotify_is_tmux_window_active
        return $status
    end

    # If inside a screen session, check if the screen window is focused
    if type -q screen
        and test -n "$STY"
        __tnotify_is_screen_window_active
        return $status
    end

    return 0
end

function __tnotify_humanize_duration -a milliseconds
    set -l seconds (math --scale=0 "$milliseconds/1000" % 60)
    set -l minutes (math --scale=0 "$milliseconds/60000" % 60)
    set -l hours (math --scale=0 "$milliseconds/3600000")

    if test $hours -gt 0
        printf '%s' $hours'h '
    end
    if test $minutes -gt 0
        printf '%s' $minutes'm '
    end
    if test $seconds -gt 0
        printf '%s' $seconds's'
    end
end

function __tnotify_send_message -a message_text
    set -l chatid 140998462
    set -l token "5035919857:AAGVr8XO1zv2IiZ-k6Xnwi4aeFEDg8mMlYQ"

    set -l doc '{"chat_id": '"$chatid"', "text": "'"$message_text"'", "parse_mode": "MarkdownV2"}'
    set -l bot_url "https://api.telegram.org/bot$token"

    curl -s -X POST -H 'Content-Type: application/json' -d "$doc" "$bot_url/sendMessage" >/dev/null
end

# verify that the system has graphical capabilities before initializing
if test -z "$SSH_CLIENT" # not over ssh
    and count (__tnotify_get_focused_window_id) >/dev/null # is able to get window id
    set __tnotify_enabled
end

if set -q __tnotify_allow_nongraphical
    and set -q __tnotify_notification_command
    set __tnotify_enabled
end

if set -q __tnotify_enabled
    set -g __tnotify_initial_window_id ''
    set -q __tnotify_min_cmd_duration; or set -g __tnotify_min_cmd_duration 5000
    set -q __tnotify_exclude; or set -g __tnotify_exclude '^git (?!push|pull|fetch)'
    set -q __tnotify_notify_sound; or set -g __tnotify_notify_sound 0
    set -q __tnotify_sway_ignore_visible; or set -g __tnotify_sway_ignore_visible 0
    set -q __tnotify_tmux_pane_format; or set -g __tnotify_tmux_pane_format '[#{window_index}]'
    set -q __tnotify_notification_duration; or set -g __tnotify_notification_duration 3000

    function __tnotify_started --on-event fish_preexec
        set __tnotify_initial_window_id (__tnotify_get_focused_window_id)
    end

    function __tnotify_ended --on-event fish_postexec
        set -l exit_status $status

        # backwards compatibility for fish < v3.0
        set -q cmd_duration; or set -l cmd_duration $CMD_DURATION

        if test $cmd_duration
            and test $cmd_duration -gt $__tnotify_min_cmd_duration # longer than notify_duration
            and not __tnotify_is_process_window_focused # process pane or window not focused

            # don't notify if command matches exclude list
            for pattern in $__tnotify_exclude
                if string match -qr $pattern $argv[1]
                    return
                end
            end

            # Store duration of last command
            set -l humanized_duration (__tnotify_humanize_duration "$cmd_duration")

            set -l result "✅ success"
            if test $exit_status -ne 0
                set result "⛔ error"
            end
            set -l wd (string replace --regex "^$HOME" "~" (pwd))
            set -l command "$argv[1]"
            set -l host_name (hostname)
            set -l message_text "$result\n\`\`\`shell\n$wd/ $command\n\`\`\`\nTook \`$humanized_duration\` on \`$host_name@$USER\`"

            __tnotify_send_message "$message_text"
        end
    end
end

function __tnotify_uninstall -e done_uninstall
    # Erase all __tnotify_* functions
    functions -e __tnotify_ended
    functions -e __tnotify_started
    functions -e __tnotify_get_focused_window_id
    functions -e __tnotify_is_tmux_window_active
    functions -e __tnotify_is_screen_window_active
    functions -e __tnotify_is_process_window_focused
    functions -e __tnotify_windows_notification
    functions -e __tnotify_run_powershell_script
    functions -e __tnotify_humanize_duration

    # Erase __done variables
    set -e __tnotify_version
end
