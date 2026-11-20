#!/bin/bash
# Gestao das chaves USB das Unidades Sanitarias (servidor de chaves).
#
#   sudo ./create_key.sh --genkey      Cria a chave de uma nova unidade (e, opcionalmente, a pen de transporte)
#   sudo ./create_key.sh --transport [--enc]
#                                      Prepara a pen de transporte de uma unidade existente
#   sudo ./create_key.sh --spare       Cria uma chave USB de arranque adicional (unidade existente)
#   sudo ./create_key.sh --rotate [--enc]
#                                      Substitui a chave da unidade (ex: chave USB perdida)
#   ./create_key.sh --list [filtro]    Lista as unidades (filtro: parte do nome, sem distinguir maiusculas)
#
# Cada unidade tem a directoria keys/<ID>-<NOME> (ex: keys/1100-CS_CERAMICA). Depois de criada,
# a unidade e sempre identificada apenas pelo ID.
#
# --enc: as chaves na pen de transporte (.lek, codigo de recuperacao e chaves a revogar) vao
# cifradas em chaves.enc com uma palavra-passe de transporte aleatoria, que fica registada em
# keys/<ID>-<NOME>/transport-password.txt para ser enviada ao tecnico por outro canal.
# As chaves substituidas ficam em keys/<unidade>/old/ e vao sempre na pen de transporte
# (directoria revogar/) para o setup.sh as remover do servidor.
# O formato da chave USB de arranque esta definido no setup.sh (usado aqui no --spare).
echoerr() { echo "$@" >&2; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
    echoerr "Uso:"
    echoerr "  sudo $0 --genkey      Cria a chave de uma nova unidade (e, opcionalmente, a pen de transporte)"
    echoerr "  sudo $0 --transport [--enc]"
    echoerr "                        Prepara a pen de transporte de uma unidade existente"
    echoerr "  sudo $0 --spare       Cria uma chave USB de arranque adicional (unidade existente)"
    echoerr "  sudo $0 --rotate [--enc]"
    echoerr "                        Substitui a chave da unidade (ex: chave USB perdida)"
    echoerr "  --enc: cifra as chaves na pen de transporte (palavra-passe enviada em separado)"
    echoerr "  $0 --list [filtro]    Lista as unidades (filtro: parte do nome, ex: 1100 ou ceramica)"
    exit 1
}

# Lista as drives USB removiveis (NAME|SIZE|TRAN|RM) em $devs.
# Se nao houver nenhuma, pede para inserir a pen e tenta mais uma vez.
detect_usb() {
    list_usb() {
        lsblk --noheadings --nodeps --output NAME,SIZE,TRAN,RM | sed 's/[[:space:]]\+/|/g' | grep "usb|1$"
    }
    devs=$(list_usb)
    if [ -z "$devs" ]; then
        read -r -p "Nenhuma pen USB encontrada. Insira a pen e carregue em ENTER... " _
        sleep 2
        udevadm settle 2>/dev/null
        devs=$(list_usb)
    fi
    if [ -z "$devs" ]; then
        echoerr "Nenhuma drive USB encontrada no servidor."
        exit 1
    fi
}

# Pede ao utilizador a drive USB a usar (de $devs) e coloca o nome em $dev (ex: sdb)
select_usb() {
    echo "Qual a drive USB pretende utilizar (SERA APAGADA COMPLETAMENTE)?"
    select dev in $devs; do
        dev=$(echo "$dev" | cut -d'|' -f1)
        if [ ! -b "/dev/$dev" ]; then
            echoerr "Opcao invalida."
            exit 2
        fi
        break
    done
}

# Pede o ID da unidade sanitaria ($hfid) e procura a sua directoria: keys/<ID>-<NOME>,
# ou keys/<ID> (unidades criadas por versoes anteriores). Coloca em $keydir e $machinename
# a directoria e o seu nome (vazios se a unidade nao existir).
ask_facility() {
    echo -n "ID da unidade sanitaria: "
    read -r hfid
    if [[ ! "$hfid" =~ ^[A-Za-z0-9_]+$ ]]; then
        echoerr "ID invalido. Use apenas letras, numeros e '_' (sem espacos nem '-')."
        exit 1
    fi

    local matches
    matches=$(find keys -mindepth 1 -maxdepth 1 -type d \( -iname "$hfid-*" -o -iname "$hfid" \) 2>/dev/null)
    if [ "$(echo "$matches" | grep -c .)" -gt 1 ]; then
        echoerr "Existe mais de uma directoria para o ID '$hfid':"
        echoerr "$matches"
        exit 1
    fi
    keydir=$matches
    machinename=$(basename "$keydir" 2>/dev/null)
}

# Coloca em $lekfile a chave da unidade em $keydir
find_lek() {
    lekfile=$(find "$keydir" -maxdepth 1 -type f -name "?*.lek" 2>/dev/null | head -1)
    if [ -z "$lekfile" ]; then
        echoerr "Nenhum ficheiro .lek encontrado em $keydir/."
        echoerr "Execute primeiro: sudo $0 --genkey"
        exit 1
    fi
}

# Coloca em $lekfile e $recoverkey a chave e o codigo de recuperacao actuais de $keydir
load_key() {
    lekfile=$(find "$keydir" -maxdepth 1 -type f -name "?*.lek" | head -1)
    recoverkey=$(grep -oE '[0-9]{6}(-[0-9]{6}){7}' "$keydir/luks-recover-key.txt" 2>/dev/null)
    if [ -z "$lekfile" ] || [ -z "$recoverkey" ]; then
        echoerr "$keydir esta incompleta (falta a .lek ou a chave de recuperacao). Remova a directoria e repita."
        exit 2
    fi
}

# Desmonta todas as particoes da drive $1 (ex: sdb)
unmount_usb() {
    local dev=$1 part
    for part in /dev/${dev}*; do
        if mount | grep -q "^$part "; then
            echo "A desmontar $part..."
            umount "$part" || { echoerr "Falhou ao desmontar $part."; exit 3; }
        fi
    done
}

# Pen de transporte: pen normal (FAT, etiqueta LUKS_SETUP) com o necessario para o setup.sh
# $1 = drive (ex: sdb)
make_transport_usb() {
    local dev=$1
    unmount_usb "$dev"

    echo "type=0c" | sfdisk --no-reread -q --wipe always "/dev/${dev}" -X dos
    if [ $? -ne 0 ]; then
        echoerr "sfdisk falhou em /dev/${dev}."
        exit 4
    fi

    # Wait for kernel to register the new partition table
    sync
    udevadm settle 2>/dev/null || sleep 2

    local part="/dev/${dev}1"
    if [ ! -b "$part" ]; then
        echoerr "Particao $part nao encontrada apos particionar. Tente novamente."
        exit 5
    fi

    if ! mkfs.fat -n LUKS_SETUP "$part" >/dev/null; then
        echoerr "mkfs.fat falhou em $part."
        exit 6
    fi

    local mnt
    mnt=$(mktemp -d)
    if ! mount "$part" "$mnt"; then
        echoerr "mount falhou em $part."
        rmdir "$mnt"
        exit 7
    fi

    # Chaves (conteudo sensivel) numa directoria temporaria: copiadas tal como estao, ou cifradas
    local failed=0 stage d old
    stage=$(mktemp -d)
    cp "$lekfile" "$stage/" || failed=1
    echo -n "$recoverkey" > "$stage/recuperacao.txt" || failed=1

    # Chaves substituidas (--rotate): o setup.sh remove-as do servidor
    for d in "$keydir"/old/*/; do
        old=$(find "$d" -maxdepth 1 -type f -name "?*.lek" | head -1)
        [ -n "$old" ] || continue
        mkdir -p "$stage/revogar"
        cp "$old" "$stage/revogar/" || failed=1
        grep -oE '[0-9]{6}(-[0-9]{6}){7}' "$d/luks-recover-key.txt" 2>/dev/null | tr -d '\n' \
            > "$stage/revogar/$(basename "$old" .lek).rec" || failed=1
    done

    if [ "$encrypt" -eq 1 ]; then
        (cd "$stage" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS) || failed=1
        tar -C "$stage" -cf - . \
            | LUKS_TRANSPORT_PASS="$(normalize_password "$password")" openssl enc -aes-256-cbc -salt \
                -pbkdf2 -iter 600000 -pass env:LUKS_TRANSPORT_PASS -out "$mnt/chaves.enc" || failed=1
        # Verificar: decifrar da pen e confirmar os checksums
        local check
        check=$(mktemp -d)
        LUKS_TRANSPORT_PASS="$(normalize_password "$password")" openssl enc -d -aes-256-cbc \
                -pbkdf2 -iter 600000 -pass env:LUKS_TRANSPORT_PASS -in "$mnt/chaves.enc" \
            | tar -C "$check" -xf - && (cd "$check" && sha256sum -c --quiet SHA256SUMS >/dev/null) || failed=1
        rm -rf "$check"
    else
        cp -r "$stage"/. "$mnt/" && diff -r "$stage" "$mnt" >/dev/null 2>&1 || failed=1
    fi
    rm -rf "$stage"

    cp "$SCRIPT_DIR/setup.sh" "$mnt/" && cmp -s "$SCRIPT_DIR/setup.sh" "$mnt/setup.sh" || failed=1
    echo "$machinename" > "$mnt/unidade.txt" || failed=1
    cat << EOF > "$mnt/LEIAME.txt" || failed=1
Pen de transporte - chave do disco da Unidade Sanitaria: $machinename

No servidor da Unidade Sanitaria, com esta pen ligada:

  Com ambiente grafico (a pen abre sozinha):
      sudo bash /media/\$USER/LUKS_SETUP/setup.sh

  Sem ambiente grafico:
      sudo mount /dev/disk/by-label/LUKS_SETUP /mnt
      sudo bash /mnt/setup.sh

O setup.sh instala a chave no servidor e transforma esta pen
na chave USB de arranque (a pen sera APAGADA).
EOF
    if [ "$encrypt" -eq 1 ]; then
        cat << EOF >> "$mnt/LEIAME.txt" || failed=1

As chaves nesta pen estao CIFRADAS. O setup.sh vai pedir a palavra-passe
de transporte, que e fornecida em separado pelo departamento de IT.
EOF
    fi
    sync
    umount "$mnt"
    rmdir "$mnt"

    if [ "$failed" -ne 0 ]; then
        echoerr "ERRO: falhou a copia/verificacao dos ficheiros para a pen."
        exit 8
    fi

    if [ "$encrypt" -eq 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M')  $password" >> "$keydir/transport-password.txt"
        if [ -n "$SUDO_UID" ]; then
            chown "$SUDO_UID:$SUDO_GID" "$keydir/transport-password.txt"
        fi
    fi
}

# Palavra-passe de transporte aleatoria, facil de ditar: 20 caracteres (~100 bits) em grupos
# de 4, sem caracteres ambiguos (0/O, 1/I). Ex: K7QM-3WXP-9RTF-HN4D-2YCV
new_password() {
    tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789' < /dev/urandom | head -c 20 | sed 's/.\{4\}/&-/g; s/-$//'
}

# Forma usada na cifra (igual a do setup.sh): sem espacos nem hifens, em maiusculas
normalize_password() {
    echo "$1" | tr -d ' -' | tr '[:lower:]' '[:upper:]'
}

# Prepara a palavra-passe se --enc
prepare_encryption() {
    if [ "$encrypt" -eq 1 ]; then
        if ! command -v openssl >/dev/null; then
            echoerr "openssl nao esta instalado. Execute: apt-get install openssl"
            exit 1
        fi
        password=$(new_password)
    fi
}

# Mostra a palavra-passe de transporte (se --enc)
show_password() {
    if [ "$encrypt" -eq 1 ]; then
        echo ""
        echo "=============================================================="
        echo "  PEN CIFRADA. Palavra-passe de transporte:"
        echo ""
        echo "      $password"
        echo ""
        echo "  Registada em $keydir/transport-password.txt"
        echo "  Enviar ao tecnico por outro canal (telefone/SMS), NUNCA junto"
        echo "  com a pen. De preferencia so depois de a pen ser entregue."
        echo "=============================================================="
    fi
}

# Gera a .lek e a chave de recuperacao em $keydir
generate_key() {
    mkdir -p "$keydir"
    local keyname
    keyname=$(uuid)
    dd if=/dev/urandom bs=1 count=256 2>/dev/null > "$keydir/$keyname.lek"

    # Create recovery key
    local keyarr=() i recoverkey
    for i in {1..8}; do
      keyarr+=($(tr -cd 0-9 </dev/urandom | head -c 6))
    done
    recoverkey=$(echo ${keyarr[*]} | tr ' ' '-')
    cat << EOF > "$keydir/luks-recover-key.txt"
Chave de recuperacao para a encriptacao do disco LUKS

Pode verificar se a nome da chave esta em /etc/crypttab e corresponde ao UUID seguinte:

    $keyname

Se e o UUID que esta em /etc/crypttab, entao pode usar a seguinte chave de recuperacao para abrir o disco:

    $recoverkey

Se a chave nao corresponder ao UUID  acima, pode usar a palavra passe colocada na instalacao.
EOF

    # Keys owned by the user who ran sudo, not root
    if [ -n "$SUDO_UID" ]; then
        chown -R "$SUDO_UID:$SUDO_GID" keys
    fi
    echo "Chave criada em $keydir."
}

# Prepara a pen de transporte da unidade $machinename (chave ja existente)
transport() {
    detect_usb
    load_key
    prepare_encryption
    select_usb
    make_transport_usb "$dev"

    echo ""
    echo "Pen de transporte preparada para '$machinename'."
    echo "Instrucoes para o servidor da Unidade Sanitaria no ficheiro LEIAME.txt da pen."
    show_password
}

# Termina se a unidade $hfid ainda nao tiver chave
require_facility() {
    if [ -z "$keydir" ] || [ ! -d "$keydir" ]; then
        echoerr "Unidade Sanitaria com ID '$hfid' nao existe em keys/."
        echoerr "Execute primeiro: sudo $0 --genkey"
        exit 1
    fi
}

require_uuid() {
    if ! command -v uuid >/dev/null; then
        echoerr "Pacote uuid nao esta instalado. Execute: apt-get install uuid"
        exit 1
    fi
}

# --list nao precisa de root
if [ "$1" = "--list" ]; then
    [ $# -le 2 ] || usage
    list=$(find keys -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
    if [ -n "$2" ]; then
        list=$(grep -iF -- "$2" <<< "$list")
    fi
    if [ -z "$list" ]; then
        echo "Nenhuma unidade sanitaria encontrada."
    else
        echo "$list"
    fi
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echoerr "Este script tem de ser executado como root (sudo)."
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/setup.sh" ]; then
    echoerr "setup.sh nao encontrado em $SCRIPT_DIR."
    exit 1
fi

# Opcao --enc (so para --transport e --rotate)
encrypt=0
if [ $# -eq 2 ] && [ "$2" = "--enc" ] && { [ "$1" = "--transport" ] || [ "$1" = "--rotate" ]; }; then
    encrypt=1
    set -- "$1"
fi

case "$1" in
--genkey)
    [ $# -eq 1 ] || usage
    require_uuid
    ask_facility
    if [ -n "$keydir" ]; then
        echoerr "Ja existe uma unidade sanitaria com o ID '$hfid': $machinename"
        echoerr "Para preparar a pen de transporte: sudo $0 --transport"
        echoerr "Para substituir a chave:           sudo $0 --rotate"
        exit 2
    fi

    echo -n "Nome da unidade sanitaria: "
    read -r hfname
    # Espacos passam a '_' e tudo em maiusculas (ex: "cs ceramica" -> CS_CERAMICA)
    hfname=$(echo "$hfname" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g; s/[[:space:]]+/_/g')
    hfname=${hfname^^}
    if [ -z "$hfname" ] || [[ "$hfname" == */* ]]; then
        echoerr "Nome invalido (nao pode ser vazio nem conter '/')."
        exit 1
    fi
    machinename="$hfid-$hfname"
    keydir="keys/$machinename"
    generate_key

    echo ""
    read -r -p "Preparar agora a pen de transporte para '$machinename'? [s/N] " resp
    if [ "$resp" = "s" ] || [ "$resp" = "S" ]; then
        read -r -p "Cifrar a pen de transporte (se viajar com alguem nao confiavel)? [s/N] " resp
        if [ "$resp" = "s" ] || [ "$resp" = "S" ]; then
            encrypt=1
        fi
        transport
    else
        echo "Pode preparar a pen mais tarde com: sudo $0 --transport [--enc]"
    fi
    ;;
--transport)
    [ $# -eq 1 ] || usage
    detect_usb
    ask_facility
    require_facility
    transport
    ;;
--spare)
    [ $# -eq 1 ] || usage
    detect_usb
    ask_facility
    require_facility
    find_lek
    select_usb

    bash "$SCRIPT_DIR/setup.sh" --make-key "$lekfile" "/dev/$dev" || exit 1

    echo ""
    echo "Chave USB de arranque preparada com sucesso."
    echo "IMPORTANTE: Guarde a USB em local seguro. Nao deixar ligada ao servidor."
    ;;
--rotate)
    [ $# -eq 1 ] || usage
    require_uuid
    detect_usb
    ask_facility
    require_facility
    load_key
    prepare_encryption

    echo ""
    echo "Vai ser criada uma nova chave para '$machinename'."
    echo "Depois de executar o setup.sh no servidor, TODAS as chaves USB actuais desta"
    echo "unidade e a chave de recuperacao actual deixam de funcionar."
    read -r -p "Continuar? [s/N] " resp
    if [ "$resp" != "s" ] && [ "$resp" != "S" ]; then
        exit 2
    fi
    select_usb

    olddir="$keydir/old/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$olddir"
    mv "$lekfile" "$keydir/luks-recover-key.txt" "$olddir/" || exit 1
    echo "Chave antiga guardada em $olddir."
    generate_key
    load_key
    make_transport_usb "$dev"

    echo ""
    echo "Pen de transporte (substituicao de chave) preparada para '$machinename'."
    echo "Executar o setup.sh no servidor; depois criar as chaves USB adicionais com --spare."
    show_password
    ;;
*)
    usage
    ;;
esac
exit 0
