SECRETS_JSON=secrets/secrets.json
LOCKED_TAR=secrets/locked.tar.gpg
SECRETS_DIRECTORY=/etc/nixos/secrets
SECRETS_SPEC_FILE=./secrets/files/spec.txt

# unlocking
unlock-json:
	gpg --output ${SECRETS_JSON} --decrypt ${SECRETS_JSON}.gpg

unlock-files:
	gpg --decrypt ${LOCKED_TAR} | tar -xf - -C ./secrets/unlocked

unlock: unlock-json unlock-files

# lock
lock-json:
	gpg --symmetric ${SECRETS_JSON}

lock-files:
	cd ./secrets/unlocked && \
	tar \
		--exclude .gitkeep \
		--exclude .gitignore \
		--exclude spec.txt \
		-cvf \
		- \
		* \
	| gpg --symmetric -o ../locked.tar.gpg

lock: lock-json lock-files

install-secrets:
	@cat $(SECRETS_SPEC_FILE) \
	| grep -v '^#' \
	| while IFS=: read filename perm owner group; do \
		install -m $$perm -o $$owner -g $$group ./secrets/files/$$file $(SECRETS_DIRECTORY)/$$file; \
	done