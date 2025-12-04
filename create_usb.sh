#!/bin/bash
echoerr() { cat <<< "$@" 1>&2; }
devs=$(lsblk --noheadings --nodeps --output NAME,SIZE,TRAN,RM | sed 's/\s\s*/|/g' | grep "usb|1$")
if [ -z $devs ]; then
    echoerr Nenhuma drive USB encontrada no servidor
    exit 1
fi
# Ask for existing health unit
echo -n "Identique a Unidade Sanitaria desta usb: "
read machinename
if [[ ! -e "keys/$machinename" ]]; then
   echo "Unidade Sanitaria Inexistente"
   exit
fi
echo "Qual a drive USB pretende utilizar (Sera apagada)?"
select dev in $devs; do
    dev=$(echo $dev | cut -d'|' -f1)
    if [ ! -b /dev/$dev ]; then
        echoerr opcao invalida
        exit 2
    fi
    spec="start=2048 size=32768 type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B bootable attrs=RequiredPartition"
    echo $spec | sfdisk --no-reread -q --wipe always /dev/${dev} -X gpt
    if [ $? -ne 0 ]; then
        echoerr sfdisk falhou, tem sudo?
        exit 3
    fi
    UNIDADE="/dev/${dev}1"
    if mount | grep -q "$UNIDADE"; then
       echo "$UNIDADE está montada. Desmontando agora..."
       sudo umount "$UNIDADE"
       echo "$UNIDADE foi desmontada."
    else
       echo "$UNIDADE não está montada."
    fi
    mkfs.fat /dev/${dev}1
    if [ $? -ne 0 ]; then
        echoerr mkfs falhou
        exit 4
    fi
    mount /dev/${dev}1 /mnt 
    if [ $? -ne 0 ]; then
        echoerr mount falhou
        exit 5
    fi

    find "keys/$machinename" -type f -name "*.BEK" -exec echo {} \; -exec cp {} /mnt \;
    find "keys/$machinename" -type f -name "*.lek" -exec echo {} \; -exec cp {} /mnt \;
    umount /mnt
    exit 0
done

