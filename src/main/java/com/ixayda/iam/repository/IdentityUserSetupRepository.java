package com.ixayda.iam.repository;

import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.UUID;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Repository;

/** All mutations are serialized by the workflow's lock on the owning user. */
@Repository
public class IdentityUserSetupRepository {

	private final JdbcClient jdbc;

	IdentityUserSetupRepository(JdbcClient jdbc) {
		this.jdbc = jdbc;
	}

	public Instant issue(UUID userId, String digest) {
		return this.jdbc.sql("""
				WITH instant AS (SELECT clock_timestamp() AS now)
				INSERT INTO iam_user_setup (user_id, token_digest, status, issued_at, expires_at, finished_at)
				SELECT :userId, :digest, 'issued', now, now + INTERVAL '30 minutes', NULL FROM instant
				ON CONFLICT (user_id) DO UPDATE SET token_digest = EXCLUDED.token_digest, status = 'issued',
				    issued_at = EXCLUDED.issued_at, expires_at = EXCLUDED.expires_at, finished_at = NULL
				RETURNING expires_at
				""").param("userId", userId).param("digest", digest)
				.query((row, index) -> row.getObject("expires_at", OffsetDateTime.class).toInstant()).single();
	}

	public boolean isUsable(UUID userId, String digest) {
		return this.jdbc.sql("""
				SELECT EXISTS (SELECT 1 FROM iam_user_setup WHERE user_id = :userId AND token_digest = :digest
				    AND status = 'issued' AND expires_at > clock_timestamp())
				""").param("userId", userId).param("digest", digest).query(Boolean.class).single();
	}

	public boolean consume(UUID userId, String digest) {
		return this.jdbc.sql("""
				UPDATE iam_user_setup SET status = 'consumed', finished_at = clock_timestamp()
				WHERE user_id = :userId AND token_digest = :digest AND status = 'issued'
				    AND expires_at > clock_timestamp()
				""").param("userId", userId).param("digest", digest).update() == 1;
	}

	public boolean cancel(UUID userId) {
		var digest = this.jdbc.sql("SELECT token_digest FROM iam_user_setup WHERE user_id = :userId AND status = 'issued'")
				.param("userId", userId).query(String.class).optional();
		if (digest.isEmpty()) {
			return false;
		}
		int changed = this.jdbc.sql("""
				UPDATE iam_user_setup SET status = 'cancelled', finished_at = clock_timestamp()
				WHERE user_id = :userId AND status = 'issued'
				""").param("userId", userId).update();
		boolean stored = this.jdbc.sql("""
				SELECT EXISTS (SELECT 1 FROM iam_user_setup WHERE user_id = :userId AND token_digest = :digest
				AND status = 'cancelled' AND finished_at IS NOT NULL)
				""").param("userId", userId).param("digest", digest.orElseThrow()).query(Boolean.class).single();
		if (changed != 1 || !stored) {
			throw new IllegalStateException("Account setup was not cancelled");
		}
		return true;
	}

}
