# Procedimento para Cifra do disco de Servidores Ubuntu LTS nas Unidades Sanitárias
(Disk encryption and decryption using USB drive for Health Facilities)

## Introdução

Os servidores nas Unidades Sanitárias que têm o Sistema Operativo Ubuntu LTS são normalmente os sistemas que albergam as aplicações e bases de dados mais importantes - dados de
pacientes. Assim é muito importante que estejam instalados de forma a garantirem a melhor segurança e proteção de dados e isso implica que o disco esteja cifrado de forma que os dados não sejam acedidos caso o servidor seja extraviado.

O objectivo deste procedimento é garantir que o disco dos servidores que armazenam os dados dos pacientes estejam cifrados e configurados de forma a facilitar a sua utilização pelos
intervenientes autorizados para tal, mas torne impossível a leitura dos dados para quem não está autorizado para tal, mantendo uma utilização facilitada do servidor em zonas remotas.

As palavras cifra e encriptação são sinónimas, mas neste documento iremos usar o termo cifra para designar o processo de máscara de dados em disco usando uma chave.

Qualquer esclarecimento adicional, poderá ser respondido pelo Responsável de Segurança do HIS.

Excepções a este procedimento terão de ser exclusivamente autorizadas pelo CDC.

## Configuração de cifra nos Servidores Ubuntu LTS

Para se configurar a cifra nos servidores, estes têm de ser reinstalados o que significa perder todas as aplicações e dados. Assim, antes de iniciar o processo de cifra do disco, tem de se:

Para se configurar a cifra nos servidores, estes têm de ser reinstalados o que significa perder todas as aplicações e dados. Assim, antes de iniciar o processo de cifra do disco, tem de se:

1. Sincronizar o servidor com a Base de Dados provincial
2. Fazer backup dos dados de todas as aplicações do servidor
3. Testar todos os backups efectuados, fazendo restore e verificar os dados extraídos.
4. Reinstalar o servidor de acordo com os procedimentos indicados a seguir (com cifra habilitada no disco)
5. Reinstalar as aplicações que existiam no servidor
6. Repor os dados no servidor
7. Testar as aplicações e os dados das mesmas

Executar estes passos demora tempo, tempo esse em que o servidor estará indisponível. É extremamente importante coordenar previamente com as várias equipas que interagem com o servidor (digitação, muzima, idmed, etc), avisando as mesmas do tempo de paragem estimado.

## Distribuição Linux

A distribuição em uso para os servidores é Ubuntu Linux LTS. A versão exacta depende do parceiro, do tipo de servidor e aplicação a correr no servidor. É recomendável o uso da versão UBUNTU 22.04 LTS, visto que as versões anteriores deixaram de ter actualizações para novas versões de pacotes, estando restringidas a actualizações de segurança (https://ubuntu.com/about/release-cycle).

Os repositórios que devem ser utilizados nos servidores são o *main*, *restricted* e *universe*. A razão para restringir o uso do repositório *multiverse* (ver https://help.ubuntu.com/community/Repositories) é que contém software que não é gratuito, não garantindo por isso o cumprimento com as regras do MISAU (ministério da saúde).

Os servidores deverão ter os pacotes actualizados através da ferramenta *apt update* e *apt upgrade*.

## Configuração da BIOS

A BIOS deve ser protegida com uma palavra-passe (respeitando as políticas de palavra-passe existentes), para a password de administração da BIOS.
O boot deve ser configurado para fazer apenas boot do disco rígido e retirar a possibilidade de fazer boot de dispositivos móveis.
É necessário garantir que todas as passwords habilitadas por defeito (SNMP, Acesso iLO, iDRAC, RSA2) sejam alteradas e deverão ser eliminados todas as contas e serviços que não sejam necessários.

## Configuração da cifra do disco

Para evitar perda de dados em caso de avaria do disco, é aconselhável que os servidores tenham no mínimo dois discos com RAID 1 configurado ou se o servidor tiver 3 ou mais discos deverá ter RAID 5 configurado, à excepção de servidores virtuais.

Deve-se preferir o RAID por *hardware*, por questões de performance, mas se o servidor não tiver uma placa de RAID, pode-se configurar o RAID por software no sistema operativo. Para mais informações sobre criação e gestão de Raids em software podem aceder à seguinte página: https://help.ubuntu.com/community/Installation/SoftwareRAID.

As partições devem ser baseadas em LVM (Logical Volume Manager) para permitir um posterior incremento ou decremento de espaço. Para mais informações sobre criação e gestão de Volume Groups podem aceder à seguinte página: https://ubuntu.com/server/docs/how-to-manage-logical-volumes.

Depois de escolher o disco a utilizar para a instalação, na altura de criação de um novo Volume Group (vg) deve escolher a cifra (escolhendo a opção “Encrypt the LVM group with LUKS”), de acordo com a imagem seguinte:



