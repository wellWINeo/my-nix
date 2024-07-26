SECRETS_JSON=secrets/secrets.json
LOCKED_TAR=secrets/locked.tar.gpg
SECRETS_DIRECTORY=/etc/nixos/secrets
SECRETS_SPEC_FILE=./secrets/files/spec.txt

# unlocking
unlock-json:
	gpg --output ${SECRETS_JSON} --decrypt ${SECRETS_JSON}.gpg

unlock-files:
	gpg --decrypt ${LOCKED_TAR} | tar -xf ./secrets/unlocked

unlock: unlock-json unlock-files

# lock
lock-json:
	gpg --symmetric ${SECRETS_JSON}

lock-files:
	tar \
		--exclude ./secrets/unlocked/.gitkeep \
		--exclude ./secrets/unlocked/.gitignore \
		--exclude ./secrets/unlocked/spec.txt \
		-cvf \
		- \
		./secrets/unlocked \
	| gpg --symmetric -o ./secrets/locked.tar.gpg

lock: lock-json lock-files

install-secrets:
	@cat $(SECRETS_SPEC_FILE) \
	| grep -v '^#' \
	| while IFS=: read filename perm owner group; do \
		install -m $$perm -o $$owner -g $$group ./secrets/files/$$file $(SECRETS_DIRECTORY)/$$file; \
	done