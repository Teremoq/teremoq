.PHONY: up down logs pki-bootstrap pki-up pki-down pki-verify pki-test

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

pki-bootstrap:
	./infra/pki/scripts/bootstrap.sh

pki-up:
	./infra/pki/scripts/start-ca.sh

pki-down:
	./infra/pki/scripts/stop-ca.sh

pki-verify:
	./infra/pki/scripts/verify.sh

pki-test:
	./infra/pki/tests/pki-smoke.sh
