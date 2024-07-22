SECRETS_FILE=secrets/secrets.json

ifeq ($(wildcard $(SECRETS_FILE)),)
unlock:
	gpg --output ${SECRETS_FILE} --decrypt ${SECRETS_FILE}.gpg
else
unlock:
	@echo "${SECRETS_FILE} already unlocked"
endif

.PHONY:
	unlock

ifeq ($(wildcard $(SECRETS_FILE)),)
lock:
	@echo "${SECRETS_FILE} not exists. Nothing to lock"
else
lock:
	gpg --symmetric ${SECRETS_FILE}
endif

cleanup-secrets:
	rm secrets/secrets.json