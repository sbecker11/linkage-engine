package com.spexture.linkage_engine;

final class LinkageEmbeddingText {

    private LinkageEmbeddingText() {
    }

    static String toEmbeddingText(String givenName, String familyName, Integer year, String location) {
        StringBuilder sb = new StringBuilder();
        sb.append("givenName=").append(givenName).append(" familyName=").append(familyName);
        if (year != null) {
            sb.append(" year=").append(year);
        }
        if (location != null && !location.isBlank()) {
            sb.append(" location=").append(location);
        }
        return sb.toString();
    }

    static String queryText(LinkageResolveRequest request) {
        return toEmbeddingText(request.givenName(), request.familyName(), request.approxYear(), request.location());
    }

    static String queryText(RecordSearchRequest request) {
        if (request.rawQuery() != null && !request.rawQuery().isBlank()) {
            return request.rawQuery();
        }
        return toEmbeddingText(request.givenName(), request.familyName(), request.approxYear(), request.location());
    }
}
