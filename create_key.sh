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
cat << EOF > "keys/$machinename/install.sh"
#!/bin/bash
echoerr() { cat <<< "\$@" 1>&2; }
sed -i "s/none luks/$keyname luks,discard,keyscript=\/bin\/luksunlockusb/g" /etc/crypttab
if [ \$? -ne 0 ]; then
    echoerr falhou a alteracao ao /etc/crypttab, tem sudo?
    exit 1
fi
EOF
cat << "EOF" >> "keys/$machinename/install.sh"
cat << "END" > /bin/luksunlockusb
#!/bin/sh
set -e
if [ ! -e /mnt ]; then
    mkdir -p /mnt
    sleep 3
fi
for usbpartition in /dev/disk/by-id/usb-*-part1; do
  if [ -e $usbpartition ]; then
    usbdevice=$(readlink -f $usbpartition)
    if mount -t vfat $usbdevice /mnt 2>/dev/null; then
        if [ -e /mnt/$CRYPTTAB_KEY.lek ]; then
            cat /mnt/$CRYPTTAB_KEY.lek
            umount $usbdevice
            exit
        fi
        umount $usbdevice
    fi
  fi
done
/lib/cryptsetup/askpass "Insira chave USB e pressione ENTER: "
END
chmod 755 /bin/luksunlockusb
EOF
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
