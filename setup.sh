#!/bin/bash
# Configuracao no servidor da Unidade Sanitaria, executado a partir da pen de transporte:
#
#     sudo bash /media/$USER/LUKS_SETUP/setup.sh        (com ambiente grafico)
#     sudo mount /dev/disk/by-label/LUKS_SETUP /mnt && sudo bash /mnt/setup.sh
#
# 1) Copia os ficheiros da pen para RAM (/run) e continua a partir da RAM.
#    Se a pen estiver cifrada (chaves.enc, create_key.sh --enc), pede a palavra-passe
#    de transporte e decifra as chaves apenas em RAM.
# 2) Instala a chave no servidor (crypttab, keyscript, initramfs, keyslots LUKS).
#    Se a pen tiver chaves antigas (revogar/, criadas pelo create_key.sh --rotate),
#    usa-as para autorizar a nova chave e remove-as do servidor no fim.
# 3) Transforma a pen de transporte na chave USB de arranque.
# 4) Apaga os ficheiros da RAM.
#
# Uso interno (create_key.sh --spare no servidor de chaves), so cria a chave USB de arranque:
#     setup.sh --make-key <ficheiro.lek> /dev/<pen USB>
echoerr() { echo "$@" >&2; }

if [ "$(id -u)" -ne 0 ]; then
    echoerr "Este script tem de ser executado como root (sudo)."
    exit 1
fi

# Chave USB de arranque: particao EFI de 16 MB (nao aparece noutros computadores) com a .lek
# $1 = pen (ex: /dev/sdb), $2 = ficheiro .lek
make_key_usb() {
    local disk=$1 lekfile=$2 mp part mnt copied

    while read -r mp; do
        [ -n "$mp" ] || continue
        umount "$mp" || { echoerr "Falhou ao desmontar $mp."; return 1; }
    done < <(lsblk -lno MOUNTPOINT "$disk")

    # Partition: EFI type so the USB appears empty on other computers
    echo "start=2048 size=32768 type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B bootable attrs=RequiredPartition" \
        | sfdisk --no-reread -q --wipe always "$disk" -X gpt
    if [ $? -ne 0 ]; then
        echoerr "sfdisk falhou em $disk."
        return 1
    fi

    # Wait for kernel to register the new partition table
    sync
    udevadm settle 2>/dev/null || sleep 2

    part="${disk}1"
    if [ ! -b "$part" ]; then
        echoerr "Particao $part nao encontrada apos particionar. Tente novamente."
        return 1
    fi

    if ! mkfs.fat -F 16 "$part" >/dev/null; then
        echoerr "mkfs.fat falhou em $part."
        return 1
    fi

    mnt=$(mktemp -d)
    if ! mount "$part" "$mnt"; then
        echoerr "mount falhou em $part."
        rmdir "$mnt"
        return 1
    fi

    cp "$lekfile" "$mnt/" && sync && cmp -s "$lekfile" "$mnt/$(basename "$lekfile")"
    copied=$?
    umount "$mnt"
    rmdir "$mnt"

    if [ "$copied" -ne 0 ]; then
        echoerr "Falhou a copia/verificacao da chave para a pen."
        return 1
    fi
    echo "  Copiado: $(basename "$lekfile")"
}

if [ "$1" = "--make-key" ]; then
    if [ $# -ne 3 ] || [ ! -f "$2" ]; then
        echoerr "Uso: $0 --make-key <ficheiro.lek> /dev/<pen USB>"
        exit 1
    fi
    if [ ! -b "$3" ] || [ "$(lsblk -dno TRAN "$3" | tr -d ' ')" != "usb" ]; then
        echoerr "$3 nao e uma drive USB."
        exit 1
    fi
    make_key_usb "$3" "$2"
    exit $?
fi

# ---------------------------------------------------------------------------
# Fase 1: a partir da pen — copiar tudo para RAM e continuar a partir da RAM
# ---------------------------------------------------------------------------
if [ "$1" != "--ram" ]; then
    here=$(cd "$(dirname "$0")" && pwd)
    part=$(findmnt -n -o SOURCE --target "$here")
    disk=$(lsblk -no PKNAME "$part" 2>/dev/null | head -1)
    if [ -z "$disk" ] || [ "$(lsblk -dno TRAN "/dev/$disk" | tr -d ' ')" != "usb" ]; then
        echoerr "Este script tem de ser executado a partir da pen USB de transporte."
        exit 1
    fi

    if [ -f "$here/chaves.enc" ]; then
        files=(setup.sh unidade.txt chaves.enc)
    else
        leks=("$here"/?*.lek)
        if [ ! -f "${leks[0]}" ] || [ "${#leks[@]}" -ne 1 ]; then
            echoerr "A pen tem de conter exactamente um ficheiro .lek."
            exit 1
        fi
        files=(setup.sh unidade.txt recuperacao.txt "$(basename "${leks[0]}")")
    fi

    ramdir=$(mktemp -d /run/luks-usb-setup.XXXXXX) || exit 1
    for f in "${files[@]}"; do
        if ! cp "$here/$f" "$ramdir/"; then
            echoerr "Falhou a copia de $f para RAM."
            rm -rf "$ramdir"
            exit 1
        fi
    done
    if [ -d "$here/revogar" ] && ! cp -r "$here/revogar" "$ramdir/"; then
        echoerr "Falhou a copia de revogar/ para RAM."
        rm -rf "$ramdir"
        exit 1
    fi

    cd /
    exec bash "$ramdir/setup.sh" --ram "/dev/$disk"
fi

# ---------------------------------------------------------------------------
# Fase 2: a partir da RAM
# ---------------------------------------------------------------------------
ramdir=$(cd "$(dirname "$0")" && pwd)
disk=$2
if [ ! -b "$disk" ] || [ "$(lsblk -dno TRAN "$disk" | tr -d ' ')" != "usb" ]; then
    echoerr "Uso: $0 --ram /dev/<pen USB>"
    exit 1
fi

cd "$ramdir" || exit 1
unidade=$(cat unidade.txt)

# Testa se a chave no ficheiro $2 abre a particao $1
key_works() { cryptsetup open --test-passphrase --key-file "$2" "$1" 2>/dev/null; }

cmds=(cryptsetup update-initramfs sfdisk mkfs.fat)
[ -f chaves.enc ] && cmds+=(openssl tar sha256sum)
for cmd in "${cmds[@]}"; do
    if ! command -v "$cmd" >/dev/null; then
        echoerr "Comando '$cmd' nao encontrado. (mkfs.fat: apt-get install dosfstools)"
        exit 1
    fi
done

devices=$(blkid --match-token TYPE=crypto_LUKS -o device)
if [ -z "$devices" ]; then
    echoerr "Nenhuma particao LUKS encontrada neste servidor."
    exit 1
fi

# A pen tem de estar desmontada para ser formatada no fim
while read -r mp; do
    [ -n "$mp" ] || continue
    if ! umount "$mp"; then
        echoerr ""
        echoerr "Nao foi possivel desmontar a pen ($mp)."
        echoerr "Feche as janelas/terminais abertos na pen e execute:"
        echoerr ""
        echoerr "    cd / && sudo bash $ramdir/setup.sh --ram $disk"
        echoerr ""
        exit 1
    fi
done < <(lsblk -lno MOUNTPOINT "$disk")

# A partir daqui os ficheiros da RAM sao sempre apagados no fim
trap 'cd / && rm -rf "$ramdir"' EXIT

# Pen cifrada: decifrar as chaves (apenas em RAM) com a palavra-passe de transporte
if [ -f chaves.enc ]; then
    echo ""
    echo "A pen esta cifrada. Introduza a palavra-passe de transporte"
    echo "(fornecida em separado pelo servidor de chaves; hifens e maiusculas sao opcionais)."
    ok=0
    for attempt in 1 2 3; do
        read -r -s -p "Palavra-passe de transporte: " pw
        echo ""
        # Normalizar: sem espacos nem hifens, em maiusculas
        pw=$(echo "$pw" | tr -d ' -' | tr '[:lower:]' '[:upper:]')
        rm -rf dec && mkdir -m 700 dec
        if LUKS_TRANSPORT_PASS="$pw" openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
                -pass env:LUKS_TRANSPORT_PASS -in chaves.enc 2>/dev/null \
                | tar -C dec --no-same-owner -xf - 2>/dev/null \
            && [ -f dec/SHA256SUMS ] && (cd dec && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1); then
            ok=1
            break
        fi
        echoerr "Palavra-passe errada."
    done
    unset pw
    if [ "$ok" -ne 1 ]; then
        echoerr "Nao foi possivel decifrar as chaves. Nada foi alterado."
        exit 1
    fi
    rm -f chaves.enc dec/SHA256SUMS
    mv dec/* . && rmdir dec
    echo "Chaves decifradas."
fi

lek=$(ls -- ?*.lek 2>/dev/null)
if [ -z "$lek" ] || [ ! -f recuperacao.txt ]; then
    echoerr "Chave (.lek) ou codigo de recuperacao em falta. Nada foi alterado."
    exit 1
fi
keyname=${lek%.lek}
shopt -s nullglob
oldkeys=(revogar/?*.lek revogar/?*.rec)
shopt -u nullglob

echo ""
echo "Unidade Sanitaria: $unidade"
echo "Pen USB:           $disk ($(lsblk -dno VENDOR,MODEL,SIZE "$disk" | xargs))"
echo "Particoes LUKS:    $(echo $devices)"
echo ""
echo "Este processo vai:"
echo "  - Adicionar a chave USB ao disco cifrado deste servidor."
if [ "${#oldkeys[@]}" -gt 0 ]; then
    echo "  - REMOVER as chaves antigas: as chaves USB antigas e a chave de recuperacao"
    echo "    antiga deixam de funcionar."
fi
echo "  - APAGAR a pen e transforma-la na chave USB de arranque."
echo ""
read -r -p "Continuar? [s/N] " resp
if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
    echo "Cancelado. Nada foi alterado."
    exit 1
fi

echo ""
echo "=== 1/2 Instalar a chave no servidor ==="

VERSION_ID=$(grep "^VERSION_ID" /etc/os-release | cut -d'"' -f2)
UBUNTU_MAJOR=$(echo "$VERSION_ID" | cut -d'.' -f1)
echo "Ubuntu $VERSION_ID detectado."

sed -i "s/none luks/$keyname luks,discard,keyscript=\/bin\/luksunlockusb/g" /etc/crypttab
# Servidor ja configurado (substituicao de chave): actualizar o nome da chave
sed -i -E "/keyscript=\/bin\/luksunlockusb/ s/^(\S+\s+\S+\s+)\S+/\1$keyname/" /etc/crypttab
if ! grep -q "keyscript=/bin/luksunlockusb" /etc/crypttab; then
    echoerr "Falhou a alteracao ao /etc/crypttab (entrada 'none luks' nao encontrada). A pen NAO foi apagada."
    exit 1
fi

cat << "END" > /bin/luksunlockusb
#!/bin/sh
# Ubuntu 24.04: o KEY_NAME do crypttab NAO chega de forma fiavel ao keyscript,
# por isso NAO se depende do nome — usa-se a .lek que estiver na pen.
# Seguranca: o LUKS valida sempre o material contra os keyslots; uma chave
# errada e simplesmente recusada (cai no askpass). Uma .lek por pen.
mkdir -p /mnt

list_parts() {
    # 1) preferir os by-id de USB; 2) fallback: qualquer particao sd*1
    for p in /dev/disk/by-id/usb-*-part1; do [ -e "$p" ] && readlink -f "$p"; done
    for p in /dev/sd*1; do [ -e "$p" ] && echo "$p"; done
}

# esperar ate ~20s que a pen apareca e contenha uma .lek
i=0
while [ "$i" -lt 20 ]; do
    for dev in $(list_parts | sort -u); do
        if mount -t vfat -o ro "$dev" /mnt 2>/dev/null; then
            for lek in /mnt/*.lek; do
                [ -e "$lek" ] || continue
                cat "$lek"
                umount /mnt 2>/dev/null
                exit 0
            done
            umount /mnt 2>/dev/null
        fi
    done
    i=$((i + 1))
    sleep 1
done
/lib/cryptsetup/askpass "Insira chave USB e pressione ENTER: "
END
chmod 755 /bin/luksunlockusb

# Ubuntu 24.04+: o initramfs-tools deixou de incluir automaticamente o keyscript
# no initramfs — é necessário um hook explícito
if [ "$UBUNTU_MAJOR" -ge 24 ]; then
    echo "Ubuntu 24.04+ detectado — a configurar hook de initramfs..."

    mkdir -p /etc/initramfs-tools/hooks
    cat << "INHOOK" > /etc/initramfs-tools/hooks/luksunlockusb
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
  prereqs) prereqs; exit 0 ;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /bin/luksunlockusb
manual_add_modules vfat nls_cp437 nls_ascii nls_iso8859-1
force_load usb_storage
force_load uas
INHOOK
    chmod 755 /etc/initramfs-tools/hooks/luksunlockusb

    # Garantir que o cryptsetup é incluído no initramfs
    CONF_HOOK=/etc/cryptsetup-initramfs/conf-hook
    if ! grep -q "^CRYPTSETUP=y" "$CONF_HOOK" 2>/dev/null; then
        echo "CRYPTSETUP=y" >> "$CONF_HOOK"
    fi
fi

failed=0
for device in $devices; do
    echo "A adicionar chaves a $device ..."
    # Autorizar com uma chave antiga que ainda abra o disco; senao pede a palavra-passe
    auth=()
    for old in revogar/?*.lek; do
        if [ -f "$old" ] && key_works "$device" "$old"; then
            auth=(--key-file "$old")
            break
        fi
    done
    cryptsetup luksAddKey "${auth[@]}" "$device" "$lek" || failed=1
    cryptsetup luksAddKey "${auth[@]}" "$device" recuperacao.txt || failed=1
    # Confirmar que a chave USB abre mesmo o disco
    key_works "$device" "$lek" || failed=1
done
if [ "$failed" -ne 0 ]; then
    echoerr "ERRO: falhou a adicao da chave a pelo menos uma particao LUKS. A pen NAO foi apagada; pode repetir."
    exit 1
fi

# So depois de a nova chave estar confirmada: remover as chaves antigas
for device in $devices; do
    for old in "${oldkeys[@]}"; do
        if key_works "$device" "$old"; then
            echo "A remover chave antiga $(basename "$old") de $device ..."
            cryptsetup luksRemoveKey "$device" "$old" || failed=1
        fi
    done
done
if [ "$failed" -ne 0 ]; then
    echoerr "ERRO: a nova chave foi instalada mas falhou a remocao de uma chave antiga. A pen NAO foi apagada; pode repetir."
    exit 1
fi

if ! update-initramfs -u; then
    echoerr "ERRO: falhou o update-initramfs. A pen NAO foi apagada; pode repetir."
    exit 1
fi

echo ""
echo "=== 2/2 Preparar a chave USB de arranque ==="
# Apagar o conteudo antigo da pen (contem a chave de recuperacao)
size_mb=$(( $(blockdev --getsize64 "$disk") / 1048576 ))
[ "$size_mb" -gt 64 ] && size_mb=64
dd if=/dev/zero of="$disk" bs=1M count="$size_mb" conv=fsync status=none

made=0          # chaves USB criadas
made_serials=() # numeros de serie das pens ja usadas (para nao as voltar a apagar)
serial=$(lsblk -dno SERIAL "$disk" | xargs)
[ -n "$serial" ] && made_serials+=("$serial")

if make_key_usb "$disk" "$ramdir/$lek"; then
    made=1
    echo "Chave USB de arranque n.o 1 criada."
else
    echoerr "ERRO: a chave foi instalada no servidor, mas falhou a preparacao desta pen."
    echoerr "Pode tentar com outra pen a seguir."
fi

# Chaves USB adicionais (ex: para o gestor distrital), enquanto a chave ainda esta em RAM
while true; do
    echo ""
    read -r -p "Criar outra chave USB de arranque (ex: para o gestor distrital)? [s/N] " resp
    if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
        break
    fi
    echo "Retire a chave USB que esta ligada e ligue a nova pen (SERA APAGADA)."
    read -r -p "Carregue em ENTER quando a nova pen estiver ligada... " _
    sleep 2
    udevadm settle 2>/dev/null

    # Pens USB removiveis que ainda nao foram usadas nesta execucao
    cands=()
    while read -r line; do
        NAME="" SERIAL="" TRAN="" RM=""
        eval "$line"
        [ "$TRAN" = "usb" ] && [ "$RM" = "1" ] || continue
        for s in "${made_serials[@]}"; do
            [ -n "$SERIAL" ] && [ "$SERIAL" = "$s" ] && continue 2
        done
        cands+=("$NAME")
    done < <(lsblk -dnP -o NAME,SERIAL,TRAN,RM)

    if [ "${#cands[@]}" -eq 0 ]; then
        echoerr "Nenhuma pen nova encontrada."
        continue
    elif [ "${#cands[@]}" -eq 1 ]; then
        newdisk="/dev/${cands[0]}"
    else
        echo "Qual a pen a utilizar?"
        select c in "${cands[@]}"; do
            [ -n "$c" ] && break
        done
        newdisk="/dev/$c"
    fi

    echo "Pen: $newdisk ($(lsblk -dno VENDOR,MODEL,SIZE "$newdisk" | xargs)) - SERA APAGADA."
    read -r -p "Continuar? [s/N] " resp
    if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
        continue
    fi
    if make_key_usb "$newdisk" "$ramdir/$lek"; then
        made=$((made + 1))
        serial=$(lsblk -dno SERIAL "$newdisk" | xargs)
        [ -n "$serial" ] && made_serials+=("$serial")
        echo "Chave USB de arranque n.o $made criada."
    else
        echoerr "ERRO: falhou a preparacao desta pen. Pode tentar com outra pen."
    fi
done

if [ "$made" -eq 0 ]; then
    echoerr ""
    echoerr "ERRO: a chave foi instalada no servidor, mas nenhuma chave USB foi criada."
    echoerr "Crie a chave USB no servidor de chaves com: sudo ./create_key.sh --spare"
    echoerr "Ate la, use a palavra-passe do disco no arranque."
    exit 1
fi

echo ""
echo "Concluido: $made chave(s) USB de arranque criada(s). Ficheiros temporarios apagados da RAM."
if [ "${#oldkeys[@]}" -gt 0 ]; then
    echo "As chaves USB antigas deixaram de funcionar."
fi
echo "Teste reiniciando o servidor com uma chave ligada; depois retire-a e guarde-a em local seguro."
exit 0
