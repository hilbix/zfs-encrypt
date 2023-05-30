> This is not complete!


# zfs-encrypt

A shell script to manage multiple encryption keys for ZFS.

> Notes:
>
> In ZFS you cannot enable encryption on existing datasets.
>
> Hence to create an entirely encrypted pool, you need to specify
> encryption already when the pool is created.
> Also be sure to specify the correct ashift value,
> as this cannot be changed later on, too.
>
> Recommendation is to set ashift=12 even on 512 byte sector drives,
> as future replacement drives very likely have 4096 bytes sectors.

This script is only meant for pools which have a encrypted root dataset.


## Usage

	git clone https://github.com/hilbix/zfs-encrypt.git
	zfs-encrypt/zfs-encrypt.sh pool

To automatically unlock ZFS, use something like

	zfs-encrypt/zfs-encrypt.sh pool <<<passphrase

or

	zfs-encrypt/zfs-encrypt.sh pool <file

Further reading:

- <https://blog.bilak.info/2021/06/15/howto-restore-zfs-encryption-hierarchies/>


## About

My recommendation is:

- Always use ZFS pool encryption.  It does not hurt.
- You can use L.U.K.S., but AFAICS it is better what `zfs` offers out of the box
  - You can fully `send`, `receive` and `scrub` encrypted pools even without passphrases
  - You can have different master keys on datasets while L.U.K.S. only supports a single one

However ZFS currently only allows a single passphrase or keyfile to unlock the master key.
This is a bit troublesome.  For data recovery, retention and backup purpose, it is good
to have multiple keys.

Based on an idea found at <https://github.com/openzfs/zfs/issues/6824#issuecomment-1166732951>
this here wraps this into a script, such that it can be easily used.

It works as follows:

- It sets a 256 bit master passphrase on ZFS.
- This passphrase is stored nowhere else than in encrypted slots
- The slots are then decrypted based on their own passphrase
- The slots are kept as User-properties with the prefix `keyslot:`

This way each slot is independent of the master passphrase on ZFS.
The slots are stored in user properties on the main dataset,
such that they are included if you backup or split ZFS.

> Note that zpools do not offer User-properties, only zfs datasets
> like filesystems, snapshots and vdevs offer these.
>
> **CAVEATS:**
>
> - If you ever use `zfs change-key`, then all the slots get invalidated,
>   as they are not automatically updated!
> - Also note that ZFS is CoW and does not wipe the old passphrase
>   data from the pool.  So as long as the old block is not reused
>   (which can take years!) the old passphrase might still be
>   available to unlock the master key.
> - The same happens if you change the passphrase of a keyslot with this script.
>   So old variants of the keyslot may stay around for some indefinite time.
> - The only way to re-encrypt the pool (and thereby make it impossible to decrypt
>   it with some leaked passphrase) is to create a new pool with another
>   master-key and then send the old pool there and destroy the old pool.
>
> Recommendation:
>
> - Never use `zfs change-key`
> - Create the pool with encryption right out the box with this script
>   - This sets a 256 bit passphrase on ZFS
>   - and stores it (encrypted with your passphrase) into slot keyslot:default
> - Add secure passphrases
> - Possibly wrap those passphrases once again into wrapped passphrases
>   to be able to remove the burden, if such wrapped passphrases escape.
>   - You cannot store this on ZFS

You should set at least 2 passphrases:

- The one used to unlock the computer
- A fallback (or recovery) one stored securely in your password safe
  which can be used in case you forget the one used to unlock the computer

The fallback one should not be used regularily, it is only for recovery.

> The recovery passphrase can be created with this script for copy and paste.


## Caveats

Restoring an encrypted pool with an encrypted root dataset can be tricky,
as you cannot receive encrypted data, as the receiving root dataset already
exists with a different master key.

Also the keyslots are stored in the user properties of the root dataset of a pool only.
Hence be sure to backup the root dataset, too.

For hints how to get rid of multiple encryptionroots, see

<https://blog.bilak.info/2021/06/15/howto-restore-zfs-encryption-hierarchies/>

> This is not from me and untested.  But looks quite promising.

Remember, that the master key of a restored dataset then is different from
the pool's master key.  If this is a problem, do as follows:

- Restore an encrypted dataset (R) somewhere else in the ZFS hierarchy
- Then activate it with the passphrase on the restored node
- Create a new destination dataset (N) which inherits the master key of the pool
- Send the restored dataset (R) unencrypted to the new destination dataset (N)
  - This is a local action, so no need to decrypt it before it leaves the backup server
- Done

Note that you can reduce the downtime, as the send can take long, as follows:

- Restore an encrypted dataset (R) to it's real position
- Then activate it (R) with the passphrase on the restored node
  - It will be used with the old master key
- Create a new destination dataset (N) somewhere else
- While it is busy, send the restored dataset (R) unencrypted to the new destination dataset (N)
- Send it again with a fresher snapshot
- Iterate until the sends are nearly instant
- Stop everything (R and N) which accesses the dataaset
- Send it again with a last snapshot
- Unmount both datasets (R and N)
- Rename away the restored dataset (R)
- Rename the destination dataset (N) to the correct name
- mount the new destination dataset (N)
- After checking that it is ok, you can drop now the old restored dataset (R)
  - I first compare and remove all data first
  - It then is dropped after everything was successfully compared and removed
  - Takes ages, but I am sure nothing was left behind
  - Snapshots (of N) are your friend (because N is busy now)

If you use `zfs change-key -l -i` instead, be sure you still have access to the old
and new key slots, as if something goes wrong, the user preferences (key slots)
may become stale, such that you can no more decode things.

> The output of `zfs list -tall all -r > keep-this-safe.txt` is your friend.
> And `grep 'keyslot:' keep-this-safe.txt`
>
> I never tested all this, so be careful!  **Here be dragons!**

I might add a check script which checks all the keyslots.  But this is still
no guarantee, then.


## FAQ

WTF why?

- Encryption must be a no-brainer, else it is unusable for me.
  - YMMV.
- [DSGVO](https://eur-lex.europa.eu/eli/reg/2016/679/oj) technically requires to encrypt backups.
  - If you cannot read this out of the law, read the DSGVO again, carefully, and think about state of the art.
  - If you still do not see the requirement, ask somebody how understands the problem better than you, like a lawyer.
  - If your lawyer does neglect the requirement to encrypt backups, look for a better lawyer.
- Data encryption is state of the art.
  - State of the art is a DSGVO requirement.
- To backup data which must be processed under the DSGVO, you need to encrypt the backups properly:
  - It is hard to impossible not to fail, if the backup is not encrypted.
  - Same is true if the data can be decrypted somehow, becauese the backup server keeps passphrases or keys, too.
- This here exactly allows you to do this. 

License?

- Free as free beer, free speech, free baby.

Automate on boot?

- T.B.D.
- Perhaps see also
  - <https://timor.site/2021/11/creating-fully-encrypted-zfs-pool/>
  - <https://github.com/chungy/zfs-boottime-encryption>

Secure?

- No guarantees, but I have done my best I can.
- This is not meant to thwart attackers.

