package com.spexture.linkage_engine;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.util.HashMap;
import java.util.Map;

/**
 * Ad-hoc DB connectivity smoke test.
 * Run manually from your IDE or `mvn -Dtest=... test`.
 */
public class TestDBConnection {
    public static void main(String[] args) {
        Map<String, String> envFileValues = loadDotEnv();
        String url = getConfig("DB_URL", envFileValues);
        String user = getConfig("DB_USER", envFileValues);
        String password = getConfig("DB_PASSWORD", envFileValues);

        if (isBlank(url) || isBlank(user) || isBlank(password)) {
            System.out.println("Missing DB_URL, DB_USER, or DB_PASSWORD in environment or .env file.");
            return;
        }

        try {
            Connection conn = DriverManager.getConnection(url, user, password);
            System.out.println("Database connection successful!");
            conn.close();
        } catch (SQLException e) {
            System.out.println("Database connection failed:");
            e.printStackTrace();
        }
    }

    private static String getConfig(String key, Map<String, String> envFileValues) {
        String fromEnv = System.getenv(key);
        if (!isBlank(fromEnv)) {
            return fromEnv;
        }
        return envFileValues.get(key);
    }

    private static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    private static Map<String, String> loadDotEnv() {
        Map<String, String> values = new HashMap<>();
        Path envPath = Path.of(".env");
        if (!Files.exists(envPath)) {
            return values;
        }
        try {
            for (String line : Files.readAllLines(envPath)) {
                String trimmed = line.trim();
                if (trimmed.isEmpty() || trimmed.startsWith("#")) {
                    continue;
                }
                int idx = trimmed.indexOf('=');
                if (idx <= 0) {
                    continue;
                }
                String key = trimmed.substring(0, idx).trim();
                String value = trimmed.substring(idx + 1).trim();
                values.put(key, value);
            }
        } catch (IOException e) {
            System.out.println("Could not read .env file: " + e.getMessage());
        }
        return values;
    }
}

