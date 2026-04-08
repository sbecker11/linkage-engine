FROM maven:3.9.9-eclipse-temurin-21 AS build
WORKDIR /workspace

COPY pom.xml .
COPY mvnw .
COPY .mvn .mvn
RUN chmod +x mvnw
RUN ./mvnw -q -DskipTests dependency:go-offline

COPY src src
RUN ./mvnw -q -DskipTests package spring-boot:repackage

FROM eclipse-temurin:21-jre
WORKDIR /app

COPY --from=build /workspace/target/linkage-engine-0.0.1-SNAPSHOT.jar /app/app.jar

EXPOSE 8080
# Sprint 8: cap heap at 1400m (leaves ~100m headroom in a 1.5GB Fargate task)
# -Xms512m pre-allocates enough heap to avoid GC pressure during Flyway startup
ENTRYPOINT ["java", "-Xmx1400m", "-Xms512m", "-jar", "/app/app.jar"]
