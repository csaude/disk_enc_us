#!/bin/bash
echoerr() { cat <<< "$@" 1>&2; }

# if ! dpkg -l | grep -q uuid; then
#   echo "Pacote uuid não está instalado. A instalar  ..."
#   sudo apt-get -y update
#   sudo apt-get install -y uuid
# else
#   echo "Pacote uuid está instalado."
# fi

# Ask for non-existing machine name
echo -n "Identique a unidade sanitaria deste servidor: "
read machinename
if [[ -d "keys/$machinename" ]]; then
    echoerr "Chave de unidade sanitaria existente."
    exit 2
fi

# Create keyfile
mkdir -p "keys/$machinename"
keyname=`uuid`
dd if=/dev/urandom bs=1 count=256 2>/dev/null > "keys/$machinename/$keyname.lek"

# Create recovery key
keyarr=()
for i in {1..8}; do
  keyarr+=($(tr -cd 0-9 </dev/urandom | head -c 6))
done
recoverkey=$(echo ${keyarr[*]} | tr ' ' '-')
cat << EOF > "keys/$machinename/luks-recover-key.txt"
Chave de recuperacao para a encriptacao do disco LUKS

Pode verificar se a nome da chave esta em /etc/crypttab e corresponde ao UUID seguinte:

    $keyname

Se e o UUID que esta em /etc/crypttab, entao pode usar a seguinte chave de recuperacao para abrir o disco:

    $recoverkey

Se a chave nao corresponder ao UUID  acima, pode usar a palavra passe colocada na instalacao.
EOF

# Create key install script
# Part 1: OS detection + crypttab modification (variable expansion needed for $keyname)
cat << EOF > "keys/$machinename/install.sh"
#!/bin/bash
echoerr() { cat <<< "\$@" 1>&2; }

# Detect Ubuntu version at install time
VERSION_ID=\$(grep "^VERSION_ID" /etc/os-release | cut -d'"' -f2)
UBUNTU_MAJOR=\$(echo "\$VERSION_ID" | cut -d'.' -f1)
echo "Ubuntu \$VERSION_ID detectado."

sed -i "s/none luks/$keyname luks,discard,keyscript=\/bin\/luksunlockusb/g" /etc/crypttab
if [ \$? -ne 0 ]; then
    echoerr "falhou a alteracao ao /etc/crypttab, tem sudo?"
    exit 1
fi
EOF

# Part 2: unlock script + Ubuntu 24.04 initramfs hook (no variable expansion)
cat << "EOF" >> "keys/$machinename/install.sh"
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
EOF

# Part 3: key installation + initramfs update (variable expansion needed)
base64key=$(cat "keys/$machinename/$keyname.lek" | base64 -w 0)
cat << EOF >> "keys/$machinename/install.sh"
echo -n "$base64key" | base64 -d > $keyname.lek
echo -n "$recoverkey" > $keyname.txt
for device in \$(blkid --match-token TYPE=crypto_LUKS -o device); do
    cryptsetup luksAddKey \$device $keyname.lek
    cryptsetup luksAddKey \$device $keyname.txt
    echo \$device
done
rm $keyname.lek
rm $keyname.txt
update-initramfs -u
EOF
