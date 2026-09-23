#!/bin/bash
echoerr() { echo "$@" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echoerr "Este script tem de ser executado como root (sudo)."
    exit 1
fi

# Detect removable USB drives
devs=$(lsblk --noheadings --nodeps --output NAME,SIZE,TRAN,RM | sed 's/[[:space:]]\+/|/g' | grep "usb|1$")
if [ -z "$devs" ]; then
    echoerr "Nenhuma drive USB encontrada no servidor."
    exit 1
fi

# Validate health unit name and key existence
echo -n "Identifique a Unidade Sanitaria desta USB: "
read machinename

if [ -z "$machinename" ]; then
    echoerr "Nome da Unidade Sanitaria nao pode ser vazio."
    exit 1
fi

if [ ! -d "keys/$machinename" ]; then
    echoerr "Unidade Sanitaria '$machinename' nao existe em keys/."
    echoerr "Execute primeiro o create_key.sh para esta unidade."
    exit 1
fi

lekfile=$(find "keys/$machinename" -maxdepth 1 -type f -name "*.lek" | head -1)
if [ -z "$lekfile" ]; then
    echoerr "Nenhum ficheiro .lek encontrado em keys/$machinename/."
    echoerr "Execute primeiro o create_key.sh para esta unidade."
    exit 1
fi

echo "Qual a drive USB pretende utilizar (SERA APAGADA COMPLETAMENTE)?"
select dev in $devs; do
    dev=$(echo "$dev" | cut -d'|' -f1)
    if [ ! -b "/dev/$dev" ]; then
        echoerr "Opcao invalida."
        exit 2
    fi

    # Unmount any partitions still mounted on this device
    for part in /dev/${dev}*; do
        if mount | grep -q "^$part "; then
            echo "A desmontar $part..."
            umount "$part" || { echoerr "Falhou ao desmontar $part."; exit 3; }
        fi
    done

    # Partition: EFI type so the USB appears empty on other computers
    spec="start=2048 size=32768 type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B bootable attrs=RequiredPartition"
    echo "$spec" | sfdisk --no-reread -q --wipe always "/dev/${dev}" -X gpt
    if [ $? -ne 0 ]; then
        echoerr "sfdisk falhou — tem sudo?"
        exit 4
    fi

    # Wait for kernel to register the new partition table
    sync
    udevadm settle 2>/dev/null || sleep 2

    UNIDADE="/dev/${dev}1"

    if [ ! -b "$UNIDADE" ]; then
        echoerr "Particao $UNIDADE nao encontrada apos particionar. Tente novamente."
        exit 5
    fi

    mkfs.fat -F 16 "$UNIDADE"
    if [ $? -ne 0 ]; then
        echoerr "mkfs.fat falhou em $UNIDADE."
        exit 6
    fi

    mount "$UNIDADE" /mnt
    if [ $? -ne 0 ]; then
        echoerr "mount falhou em $UNIDADE."
        exit 7
    fi

    # Copy key files and verify each one
    copied=0
    failed=0
    while IFS= read -r -d '' f; do
        filename=$(basename "$f")
        if cp "$f" "/mnt/$filename"; then
            echo "  Copiado: $filename"
            copied=$((copied + 1))
        else
            echoerr "  FALHOU ao copiar: $filename"
            failed=$((failed + 1))
        fi
    done < <(find "keys/$machinename" -maxdepth 1 -type f -name "*.lek" -print0)

    sync
    umount /mnt

    if [ "$failed" -gt 0 ]; then
        echoerr "ERRO: $failed ficheiro(s) nao foram copiados. USB pode estar inutilizavel."
        exit 8
    fi

    if [ "$copied" -eq 0 ]; then
        echoerr "ERRO: Nenhum ficheiro .lek foi copiado."
        exit 8
    fi

    echo ""
    echo "USB preparada com sucesso ($copied ficheiro(s) copiado(s))."
    echo "IMPORTANTE: Desmonte a USB e guarde-a em local seguro. Nao deixar ligada ao servidor."
    exit 0
done
