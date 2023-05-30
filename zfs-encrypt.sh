#!/bin/bash
# vim: ft=bash
#
# Set ZFS encryption

STDOUT() { local e=$?; printf %q "$1"; [ 2 -gt $# ] || printf ' %q' "${@:2}"; printf '\n'; return $e; }
STDERR() { local e=$?; STDOUT "$@" >&2; return $e; }
OOPS() { STDERR OOPS: "$@"; exit 23; }
x() { "$@"; STDERR exec $?: "$@"; }
o() { "$@" || OOPS fail $?: "$@"; }
t() { "$@"; exit; }
v() { local -n __VAR__="$1"; __VAR__="$("${@:2}")"; }
ov() { v "$@" || OOPS fail $? setting "$1" from: "${@:2}"; }

export LC_ALL=C.UTF-8

SUDO=
[ 0 = "`id -u`" ] || SUDO=sudo

python3 -c 'from cryptography.hazmat.primitives.ciphers.aead import AESGCM' || OOPS python3 and python3-cryptography are needed

OPTIONS="-o ashift=${ASHIFT:-12} -o feature@encryption=enabled -O encryption=on -O keyformat=passphrase"

getall()
{
  ov ALL $SUDO zfs get all "$POOL"
  ov "$@" <<<"$ALL"
}

get-slots()
{
  getall slots awk '$2 ~ /^keyslot:/ { print substr($2,9) }'
}

get-keys()
{
  getall keys awk '$2 ~ /^keyslot:/ { print $3 }'
}

# get-keystatus to see if the key is loaded
get-keystatus()
{
  # If encrypted, the encryptionroot is nonempty
  ov keystatus $SUDO zfs get -Ho value keystatus "$1"
  case "$keystatus" in
  (available)	return 0;;
  esac
  return 1
}

# If encrypted, the encryptionroot is nonempty
get-encroot()
{
  ov encroot $SUDO zfs get -Ho value encryptionroot "$1"
  case "$encroot" in
  (''|'-')	return 1;;
  esac
  return 0
}

# Not needed, as encryptionroot is readonly even on create
#get-encroots()
#{
#  ov encroots $SUDO zfs get -rHo value encryptionroot "${POOL%%/*}"
#  ov encroots sort -u <<<"$encroots"
#  encroots=$'\n'"$encroots"$'\n'
#  encroots="${encroots/$'\n-\n'/$'\n'}"
#  encroots="${encroots#$'\n'}"
#  encroots="${encroots%$'\n'}"
#  case "${encroots//$'\n'/}" in
#  (*[^a-zA-Z0-9/_-]*)	OOPS unsupported character in encryptionroot: "$encroots";;
#  esac
#  encroots=($encroots)
#}

passphrase()
{
  read -srp "${*:2}: " "$1" || OOPS EOF
  echo
  pass="$(printf %s "${!1}" | sha256sum -)" 
  pass="${pass%% *}"
}

passphrase2()
{
  passphrase P1 enter a new passphrase 'for' "$@"
  passphrase P2 reenter new passphrase 'for' "$@"
  [ ".$P1" = ".$P2" ] || OOPS passphrases 'do' not match
}

prompt()
{
  read -rp "${*:2}: " "$1" && [ -n "${!1}" ]
}

confirm()
{
  STDERR "${@:2}"
  read -rp "type '$1' (without quotes) to continue: " ans &&
  [ ".$1" = ".$ans" ] ||
  STDERR aborted
}

get-random()
{
  local -n __GR__="$1"

  ov __GR__ od -N32 -vAn -tx1 /dev/urandom
  __GR__="${__GR__// /}"
  __GR__="${__GR__//$'\n'/}"
  [ 64 = "${#__GR__}" ] || OOPS did not get the expected random bytes
}

# passphrase(hex) str -> nonce:data(hex)
aes-gcm-encrypt()
{
  # WTF? OpenSSL does not support aes-gcm?
  o python3 -c '
import sys, os;
from cryptography.hazmat.primitives.ciphers.aead import AESGCM;
def B(s): return s.encode("utf-8");
def D(s): return bytes.fromhex(s);
nonce = os.urandom(12);
print(nonce.hex()+":"+AESGCM(D(sys.argv[1])).encrypt(nonce,B(sys.argv[2]),None).hex());
' "$@"

}

# passphrase(hex) nonce:data(hex).. -> str
# returns the first decodable string
aes-gcm-decrypt()
{
  # WTF? OpenSSL does not support aes-gcm?
  o python3 -c '
import sys;
from cryptography.hazmat.primitives.ciphers.aead import AESGCM;
def D(s): return bytes.fromhex(s);
aes  = AESGCM(D(sys.argv[1]));
for a in sys.argv[2:]:
	nonce,data = a.split(":");
	try:
		print(aes.decrypt(D(nonce),D(data),None).decode("utf-8"));
		break;
	except:
		pass;
' "$@"
}

automatic()
{
  get-keys
}

interactive()
{
  cat <<EOF

Workaround as of https://github.com/openzfs/zfs/issues/6824#issuecomment-1166732951
to emulate multiple key slots for use with ZFS encryption.

Recommendation: Use ZFS pool wide slots, not on individual ZFS datasets.

Manage interactively (needs a TTY):

	$0 pool

Automatic load keys from file or passphrase:

	$0 pool <file
	$0 pool <<<'passphrase'

Prompt for passphrase and load keys:

	$0 pool | zfs load-key -L prompt pool

Prompt for passphrase and output the real single zfs passphrase
(Danger!  DO NOT LET OTHERS SEE THIS OUTPUT!):

	$0 pool | cat

Create encrypted zfs volume (on existing but non-encrypted pool):

	$0 pool/path

Create a new fully encrypted pool:

	$0 pool vdev..

The latter is needed as following cannot work (pool is missing):

	$0 pool | zpool create $OPTIONS pool vdev..

If you need another ashift, use

	ASHIFT=N $0 pool vdev..

To set options (yes, this is a hack), use /bin/bash with something like:

	printf -v ASHIFT '%q ' 12 options..
	ASHIFT="$ASHIFT" $0 pool vdev..

EOF

  get-slots
  
  case " $slots " in
  ('  ')
	STDERR there are currently no slots defined
	slot-default && get-slots
  	echo
	;;
  (*' recovery '*)	;;
  (*)	STDERR there is no recovery slot defined
	slot-auto recovery && get-slots
  	echo
	;;
  esac

  PS3=$'\n'"Enter which slot to manage: "
  echo
  select ACT in "create new slot" "exit this script" $slots
  do
  	case "$ACT" in
	('create new slot')	slot-new;;
	('exit this script')	exit;;
	('')			slot-new "$REPLY";;
	(*) case " $slots " in
	(*" $ACT "*)	slot-edit "$ACT";;
	(*)		slot-new "$REPLY";;
	esac
	esac
	echo
  done
}

slot-default()
{
  passphrase P enter passphrase of current pool
}

slot-auto()
{
  cat <<EOF

This creates a slot named "$1" with a passphrase which should be copied somewhere and kept safe.

EOF
  prompt hint enter some hint where you will hide this key || return
}

slot-new()
{
  slot="$1"
  [ -n "$1" ] || prompt slot enter new slot name || return

  case "$slot" in
  (*[^A-Za-z0-9_]*)	STDERR please only use letters numbers or _: "$slot"; return;;
  esac

  passphrase P enter passphrase 'for' existing slot:
}

slot-edit()
{
  STDOUT editing "$1"
}

get-seed-slot()
{
  passphrase2 "$@"

  get-random seed
  ov slot aes-gcm-encrypt "$pass" "$seed"
  ov cmp  aes-gcm-decrypt "$pass" "$slot"
  [ ".$cmp" = ".$seed" ] || OOPS internal error: encrypted data cannot be decrypted
}

zfs-create()
{
  # Parent already is encrypted
  parent="${POOL%/*}"
  if	get-encroot "$parent"
  then
	if	get-keystatus "$parent" ||
		{
		STDERR please load key of "$parent"
		v parentkey "$0" "${POOL%/*}" &&
		x $SUDO zfs load-key -L prompt "$parent" <<<"$parentkey"
		} 
	then
		# inherit the already loaded master key from the parent
		o $SUDO zfs create -o encryption=on "$POOL"
		return
	fi
  fi

  # Perhaps implement in future to reuse other encrypted keys in the ZFS hierarchy
  # like: select root in "${encroots[@]}"; do o $SUDO zfs create -o encryption=on -o ??? "$POOL"; return; done
  #[ 0 = "${#encroots[@]}" ] || OOPS sorry: multiple different encryption roots not supported by this script

  #confirm "$POOL" create first encrypted dataset on pool || return

  STDERR WARNING: the parent cannot be used as encryption source
  STDERR WARNING: So we create a new dataset encryption root
  get-seed-slot default key slot

  o $SUDO zfs create -o encryption=on -o keyformat=passphrase -o keyslot:default="$slot" "$POOL" <<<"$seed"$'\n'"$seed"
}

pool-create()
{
  [ ".$POOL" = ".${POOL%/*}" ] || OOPS zpool create does not support paths: "$POOL"

  # eval is evil?  Needed here to expand $ASHIFT properly
  o eval 'CMD=($SUDO zpool create '"$OPTIONS"')'

  #o confirm "/$POOL/" about to run: "${CMD[@]}" "$POOL" "$@"
  STDERR about to run: "${CMD[@]}" "$POOL" "$@"

  # It is a PITA to first enter passphrases and then fail confirming
  # Hence we do it the other way round
  get-seed-slot default key slot

  o "${CMD[@]}" -O keyslot:default="$slot" "$POOL" "$@" <<<"$seed"$'\n'"$seed"
}

test()
{
  pw="secret"
  key="$(printf %s "$pw" | sha256sum -)" 
  key="${key%% *}"
  murx=4d3b4c672af9c989931bcc70:63da575c75132b71ed1c04315087740ac0a444640fa1940f7effe6
  
  printf 'KEY %q\n' "$key"
  ov hex aes-gcm-encrypt "$key" "heho world"
  ov out aes-gcm-decrypt "$key" "$murx" "$hex"
  printf 'DEC %q\n' "$out"
  exit 0
}

POOL="$1"
[ -n "$POOL" ] && shift || OOPS must give the pool as first argument

# newly create encrypted ZFS pool
[ -z "$*" ] || t pool-create "$@"

# make sure argument exists and is usable
# '/' in '$POOL' may work but is untested
o $SUDO zpool status "${POOL%%/*}" >/dev/null

# check for existing dataaset, else drop into create mode
x $SUDO zfs get all "$POOL" >/dev/null || t zfs-create

# This must run on some pool or dataset with encryption enabled
get-encroot "$POOL" || STDERR Note: Give a ZFS dataset which is encrypted. || OOPS Encryption not enabled on dataset: "$POOL"

# load keys from file or piped passphrase
tty >/dev/null || t load-keys

# if we are piping, outout the passphrase
tty <&1 >/dev/null || t automatic

# else drop into interactive managament mode
t interactive


