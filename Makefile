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

cleanup-secrets:
	rm secrets/secrets.json