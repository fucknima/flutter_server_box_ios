import Foundation

enum SrvBoxScript {
    static let separator = "SrvBoxSep"
    static let customCmdSep = "SrvBoxCusCmdSep"
    static let dataPrefix = "SrvBoxData."

    static let scriptFileName = "srvboxm_v1.sh"
    static let scriptDirHome = "~/.config/server_box"
    static let scriptDirTmp = "/tmp/server_box"

    static func cmdSeparator(_ name: String) -> String {
        "\(separator).b64.\(encodeName(name))"
    }

    static func customCmdSeparator(_ name: String) -> String {
        "\(customCmdSep).b64.\(encodeName(name))"
    }

    static func customResultKey(_ name: String) -> String {
        "\(customCmdSep).\(name)"
    }

    static func encodeName(_ name: String) -> String {
        var base64 = Data(name.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        while base64.hasSuffix("=") {
            base64 = String(base64.dropLast())
        }
        return base64
    }

    static func decodeName(_ encoded: String) -> String? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        if padding > 0 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static let unixScriptHeader = #"""
    #!/bin/sh
    # Script for ServerBox app v1.0.1
    # DO NOT delete this file while app is running

    export LANG=en_US.UTF-8

    # If macSign & bsdSign are both empty, then it's linux
    macSign=$(uname -a 2>&1 | grep "Darwin")
    bsdSign=$(uname -a 2>&1 | grep "BSD")

    # Link /bin/sh to busybox?
    isBusybox=$(ls -l /bin/sh | grep "busybox")

    userId=$(id -u)

    exec 2>/dev/null

    """#

    static func framedCommand(_ marker: String, _ command: String) -> String {
        let body = command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ":"
            : command
        return """
        printf '%s\\n' '\(marker)'
        {
        \(body)
        } | sed 's/^/\(dataPrefix)/'
        """
    }

    static func tabbed(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : "\t\($0)" }
            .joined(separator: "\n")
    }

    static let linuxStatusCommands: [(name: String, command: String)] = [
        ("echo", "echo linux"),
        ("time", "date +%s"),
        ("net", "cat /proc/net/dev"),
        ("sys", "cat /etc/*-release | grep ^PRETTY_NAME"),
        ("cpu", "cat /proc/stat | grep cpu"),
        ("uptime", "uptime"),
        ("conn", "cat /proc/net/snmp"),
        ("disk", "(lsblk --bytes --json --output FSTYPE,PATH,NAME,KNAME,MOUNTPOINT,FSSIZE,FSUSED,FSAVAIL,FSUSE%,UUID 2>/dev/null && echo \"LSBLK_SUCCESS\") || df -k"),
        ("mem", "cat /proc/meminfo | grep -E 'Mem|Swap'"),
        ("tempType", "cat /sys/class/thermal/thermal_zone*/type"),
        ("tempVal", "cat /sys/class/thermal/thermal_zone*/temp"),
        ("host", "cat /etc/hostname"),
        ("diskio", "cat /proc/diskstats"),
        ("battery", "for f in /sys/class/power_supply/*/uevent; do cat \"$f\"; echo; done"),
        ("nvidia", "nvidia-smi -q -x"),
        ("amd", "if command -v amd-smi >/dev/null 2>&1; then amd-smi list --json && amd-smi metric --json; elif command -v rocm-smi >/dev/null 2>&1; then rocm-smi --json || rocm-smi --showunique --showuse --showtemp --showfan --showclocks --showmemuse --showpower; elif command -v radeontop >/dev/null 2>&1; then timeout 2s radeontop -d - -l 1 | tail -n +2; else echo \"No AMD GPU monitoring tools found\"; fi"),
        ("sensors", "sensors"),
        ("diskSmart", "for d in $(lsblk -dn -o KNAME); do smartctl -a -j /dev/$d; echo; done"),
        ("cpuBrand", "cat /proc/cpuinfo | grep \"model name\""),
    ]

    static let bsdStatusCommands: [(name: String, command: String)] = [
        ("echo", "echo bsd"),
        ("time", "date +%s"),
        ("net", "netstat -ibn"),
        ("sys", "uname -or"),
        ("cpu", "top -l 1 | grep \"CPU usage\""),
        ("uptime", "uptime"),
        ("disk", "df -k"),
        ("mem", "if [ \"$(uname -s)\" = \"Darwin\" ]; then top -l 1 | grep PhysMem; else top -b -d 1 | grep \"^Mem:\"; fi"),
        ("host", "hostname"),
        ("cpuBrand", "sysctl -n machdep.cpu.brand_string"),
    ]

    static let unixProcessCommand = #"""
    srvbox_command_tail() {
    	srvbox_value=$1
    	srvbox_count=$2
    	while [ "$srvbox_count" -gt 0 ]; do
    		srvbox_value=${srvbox_value#"${srvbox_value%%[![:space:]]*}"}
    		srvbox_field=${srvbox_value%%[[:space:]]*}
    		srvbox_value=${srvbox_value#"$srvbox_field"}
    		srvbox_count=$((srvbox_count - 1))
    	done
    	srvbox_value=${srvbox_value#"${srvbox_value%%[![:space:]]*}"}
    	printf '%s' "$srvbox_value"
    }

    if [ "$macSign" = "" ] && [ "$bsdSign" = "" ]; then
    	if [ "$isBusybox" != "" ]; then
    		printf 'PID USER %CPU %MEM VSZ RSS TTY STAT TIME START_ID READ_BYTES WRITE_BYTES COMMAND\n'
    		ps w | while IFS= read -r line; do
    			case "$line" in PID*) continue ;; esac
    			set -f
    			set -- $line
    			set +f
    			[ "$#" -ge 4 ] || continue
    			pid=$1; user=$2; time=$3
    			cmd=$(srvbox_command_tail "$line" 3)
    			start_id='-'
    			read_bytes='-'
    			write_bytes='-'
    			if [ -r "/proc/$pid/stat" ]; then
    				start_id=$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}')
    				[ -n "$start_id" ] || start_id='-'
    			fi
    			if [ -r "/proc/$pid/io" ]; then
    				read_bytes=$(awk '/^read_bytes:/ {print $2}' "/proc/$pid/io")
    				write_bytes=$(awk '/^write_bytes:/ {print $2}' "/proc/$pid/io")
    				[ -n "$read_bytes" ] || read_bytes='-'
    				[ -n "$write_bytes" ] || write_bytes='-'
    			fi
    			printf '%s %s - - - - - - %s %s %s %s %s\n' "$pid" "$user" "$time" "$start_id" "$read_bytes" "$write_bytes" "$cmd"
    		done
    	else
    		printf 'PID USER %CPU %MEM VSZ RSS TTY STAT TIME START_ID READ_BYTES WRITE_BYTES COMMAND\n'
    		ps -axo pid=,user=,%cpu=,%mem=,vsz=,rss=,tty=,stat=,time=,args= | while IFS= read -r line; do
    			set -f
    			set -- $line
    			set +f
    			pid=$1; user=$2; cpu=$3; mem=$4; vsz=$5; rss=$6; tty=$7; stat=$8; time=$9
    			cmd=$(srvbox_command_tail "$line" 9)
    			start_id='-'
    			read_bytes='-'
    			write_bytes='-'
    			if [ -r "/proc/$pid/stat" ]; then
    				start_id=$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}')
    				[ -n "$start_id" ] || start_id='-'
    			fi
    			if [ -r "/proc/$pid/io" ]; then
    				read_value=$(awk '/^read_bytes:/ {print $2}' "/proc/$pid/io")
    				write_value=$(awk '/^write_bytes:/ {print $2}' "/proc/$pid/io")
    				[ -n "$read_value" ] && read_bytes=$read_value
    				[ -n "$write_value" ] && write_bytes=$write_value
    			fi
    			printf '%s %s %s %s %s %s %s %s %s %s %s %s %s\n' "$pid" "$user" "$cpu" "$mem" "$vsz" "$rss" "$tty" "$stat" "$time" "$start_id" "$read_bytes" "$write_bytes" "$cmd"
    		done
    	fi
    else
    	printf 'PID USER %CPU %MEM VSZ RSS TTY STAT TIME START_ID READ_BYTES WRITE_BYTES COMMAND\n'
    	ps -axo pid=,user=,%cpu=,%mem=,vsz=,rss=,tty=,state=,time=,lstart=,command= | while IFS= read -r line; do
    		set -f
    		set -- $line
    		set +f
    		[ "$#" -ge 14 ] || continue
    		pid=$1; user=$2; cpu=$3; mem=$4; vsz=$5; rss=$6; tty=$7; stat=$8; time=$9
    		start_id=${10}_${11}_${12}_${13}_${14}
    		cmd=$(srvbox_command_tail "$line" 14)
    		printf '%s %s %s %s %s %s %s %s %s %s - - %s\n' "$pid" "$user" "$cpu" "$mem" "$vsz" "$rss" "$tty" "$stat" "$time" "$start_id" "$cmd"
    	done
    fi
    """#

    static let unixShutdownCommand = #"""
    if [ "$userId" = "0" ]; then
    	shutdown -h now
    else
    	sudo -S shutdown -h now
    fi
    """#

    static let unixRebootCommand = #"""
    if [ "$userId" = "0" ]; then
    	reboot
    else
    	sudo -S reboot
    fi
    """#

    static let unixSuspendCommand = #"""
    if [ "$userId" = "0" ]; then
    	systemctl suspend
    else
    	sudo -S systemctl suspend
    fi
    """#

    static func buildScript(
        customCmds: [String: String],
        disabledCmdTypes: [String]
    ) -> String {
        var script = unixScriptHeader

        script += statusFunction(
            customCmds: customCmds,
            disabledCmdTypes: disabledCmdTypes
        )
        script += "\n"
        script += processFunction()
        script += "\n"
        script += shutdownFunction()
        script += "\n"
        script += rebootFunction()
        script += "\n"
        script += suspendFunction()
        script += "\n"

        script += """
        case $1 in
          '-s')
            SbStatus
            ;;
          '-p')
            SbProcess
            ;;
          '-sd')
            SbShutdown
            ;;
          '-r')
            SbReboot
            ;;
          '-sp')
            SbSuspend
            ;;
          *)
            echo "Invalid argument $1"
            ;;
        esac
        """
        return script
    }

    static func statusFunction(
        customCmds: [String: String],
        disabledCmdTypes: [String]
    ) -> String {
        let linuxFrames = linuxStatusCommands
            .filter { !disabledCmdTypes.contains("linux.\($0.name)") }
            .map { framedCommand(cmdSeparator($0.name), $0.command) }
            .joined(separator: "")
        let bsdFrames = bsdStatusCommands
            .filter { !disabledCmdTypes.contains("bsd.\($0.name)") }
            .map { framedCommand(cmdSeparator($0.name), $0.command) }
            .joined(separator: "")
        let linuxBody = linuxFrames.isEmpty ? ":" : linuxFrames
        let bsdBody = bsdFrames.isEmpty ? ":" : bsdFrames

        var custom = ""
        if !customCmds.isEmpty {
            var sb = ""
            for entry in customCmds.sorted(by: { $0.key < $1.key }) {
                let framed = framedCommand(
                    customCmdSeparator(entry.key),
                    entry.value
                )
                sb += "\n" + framed
            }
            custom = sb
        }

        let body = """
        if [ "$macSign" = "" ] && [ "$bsdSign" = "" ]; then
        \(tabbed(linuxBody))
        else
        \(tabbed(bsdBody))
        fi
        """
        return """
        SbStatus() {
        \(tabbed(body))
        \(custom)
        }

        """
    }

    static func processFunction() -> String {
        "SbProcess() {\n\(tabbed(unixProcessCommand))\n}\n\n"
    }

    static func shutdownFunction() -> String {
        "SbShutdown() {\n\(tabbed(unixShutdownCommand))\n}\n\n"
    }

    static func rebootFunction() -> String {
        "SbReboot() {\n\(tabbed(unixRebootCommand))\n}\n\n"
    }

    static func suspendFunction() -> String {
        "SbSuspend() {\n\(tabbed(unixSuspendCommand))\n}\n\n"
    }

    // MARK: - Script paths

    enum ScriptLocation: Equatable {
        case tmp
        case home

        var directory: String {
            switch self {
            case .tmp: return scriptDirTmp
            case .home: return scriptDirHome
            }
        }
    }

    static func scriptPath(in location: ScriptLocation) -> String {
        "\(location.directory)/\(scriptFileName)"
    }

    static func installCommand(to location: ScriptLocation) -> String {
        let dir = location.directory
        let path = scriptPath(in: location)
        return """
        mkdir -p \(dir)
        cat > \(path)
        chmod 755 \(path)
        """
    }

    static func execCommand(
        _ function: String,
        at location: ScriptLocation,
        flag: String
    ) -> String {
        "sh \(scriptPath(in: location)) -\(flag)"
    }

    // MARK: - Output parsing

    static func parseScriptOutput(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        if raw.isEmpty { return result }

        var currentKey: String?
        var framedOutput = false
        var buffer: [String] = []

        func flush() {
            guard let key = currentKey else { return }
            let output = buffer.joined(separator: "\n")
            result[key] = framedOutput ? output : output.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll(keepingCapacity: true)
        }

        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            if index == lines.count - 1 && rawLine.isEmpty { continue }
            let line = rawLine.hasSuffix("\r")
                ? String(rawLine.dropLast())
                : String(rawLine)
            if let marker = parseMarker(line) {
                flush()
                currentKey = marker.custom
                    ? customResultKey(marker.name)
                    : marker.name
                framedOutput = marker.framed
            } else if currentKey != nil {
                if framedOutput && line.hasPrefix(dataPrefix) {
                    buffer.append(String(line.dropFirst(dataPrefix.count)))
                } else {
                    buffer.append(line)
                }
            }
        }
        flush()
        return result
    }

    private static func parseMarker(_ line: String) -> (name: String, framed: Bool, custom: Bool)? {
        let isCustom = line.hasPrefix("\(customCmdSep).")
        let prefix: String
        if line.hasPrefix("\(separator).") {
            prefix = "\(separator)."
        } else if isCustom {
            prefix = "\(customCmdSep)."
        } else {
            return nil
        }
        let value = String(line.dropFirst(prefix.count))
        guard value.hasPrefix("b64.") else { return nil }
        guard let name = decodeName(String(value.dropFirst("b64.".count))) else {
            return nil
        }
        return (name: name, framed: true, custom: isCustom)
    }
}
