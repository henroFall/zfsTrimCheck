#!/bin/bash

echo "===  ZFS Pool TRIM Detection Script   ==="
echo
echo "This sweeps your host server and examines"
echo "all drives to ensure the SSD filesystem"
echo "TRIM is enabled. It will only ask for SSD."
echo

for pool in $(zpool list -H -o name); do
    echo "🔍 Pool: $pool"

    vdevs=()
    in_config=0

    while IFS= read -r line; do
        [[ "$line" =~ ^config: ]] && in_config=1 && continue
        [[ "$line" =~ ^errors: ]] && in_config=0

        if (( in_config )); then
            if [[ "$line" =~ ^[[:space:]]{2,}([a-zA-Z0-9/_.:-]+)[[:space:]]+ONLINE ]]; then
                entry="${BASH_REMATCH[1]}"
                if [[ "$entry" != mirror* && "$entry" != raidz* && "$entry" != log && "$entry" != cache && "$entry" != spare ]]; then
                    vdevs+=("$entry")
                fi
            fi
        fi
    done < <(zpool status "$pool")

    if [[ ${#vdevs[@]} -eq 0 ]]; then
        echo "⚠️  No leaf vdevs found"
        echo
        continue
    fi

    echo "   Found vdevs:"
    printf "     - %s\n" "${vdevs[@]}"
    echo

    is_ssd=false

    for vdev in "${vdevs[@]}"; do
        devpath=$(readlink -f "/dev/disk/by-id/$vdev" 2>/dev/null)
        [[ -z "$devpath" ]] && devpath="/dev/$vdev"
        [[ ! -b "$devpath" ]] && continue

        # Get base device (strip partition number safely)
        base=$(basename "$devpath")
        devname=$(basename "$devpath")
        if [[ "$devname" =~ ^nvme[0-9]+n[0-9]+p[0-9]+$ ]]; then
            base=$(echo "$devname" | sed 's/p[0-9]\+$//')
        elif [[ "$devname" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
            base="$devname"  # already base device, don't modify
        else
            base=$(echo "$devname" | sed 's/[0-9]\+$//')
        fi
        # echo "   🔧 devpath = $devpath"
        # echo "   🔧 devname = $devname"
        # echo "   🔧 base    = $base"
        # echo "   🔧 checking: /sys/block/$base/queue/rotational"
        rota_file="/sys/block/$base/queue/rotational"
        model_file="/sys/block/$base/device/model"

        if [[ -f "$rota_file" ]]; then
            rota=$(cat "$rota_file")
            model=$(cat "$model_file" 2>/dev/null)
            echo "   ➤ /dev/$base (Model: ${model:-unknown}) → ROTA=$rota"

            if [[ "$rota" == "0" ]]; then
                echo "   ✅ Detected SSD: /dev/$base"
                is_ssd=true
                break
            fi
        else
            echo "   ⚠️  Cannot read /sys/block/$base/queue/rotational"
        fi
    done

    if $is_ssd; then
        autotrim=$(zpool get -H -o value autotrim "$pool")
        if [[ "$autotrim" == "on" ]]; then
            echo "✅ $pool: TRIM already enabled (SSD)"
        else
            echo "⚠️  $pool: TRIM is OFF (SSD)"
            read -p "Enable TRIM on $pool? [y/N] " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                zpool set autotrim=on "$pool" && echo "✔️ Enabled TRIM on $pool"
            else
                echo "❌ Skipped $pool"
            fi
        fi
    else
        echo "🛑 $pool: No SSDs detected — skipping"
    fi

    echo
done