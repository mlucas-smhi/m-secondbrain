# Reviewed upstream 9.0 source. No floating main checkout.
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ADD --checksum=sha256:2bf2bd6bd405bb7a296eec2f1e0cd853e018fc78349c54112565ebcc71d635e2 https://codeload.github.com/litegraphdb/litegraph/tar.gz/e1b32136603e158d6f5b0031413eac1ef1ed30f9 /source.tar.gz
WORKDIR /source
RUN tar -xzf /source.tar.gz --strip-components=1
COPY existing-schema.patch /existing-schema.patch
RUN sed -i 's/\r$//' src/LiteGraph/GraphRepositories/Postgresql/PostgresqlGraphRepository.cs \
    && git apply --check /existing-schema.patch \
    && git apply /existing-schema.patch
RUN dotnet publish src/LiteGraph.Server/LiteGraph.Server.csproj \
    -c Release -f net10.0 -o /publish \
    /p:UseAppHost=false /p:GeneratePackageOnBuild=false \
    /p:ErrorOnDuplicatePublishOutputFiles=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0
WORKDIR /app
COPY --from=build /publish ./
COPY --from=build /source/LICENSE.md /app/UPSTREAM-LICENSE.md
COPY supabase-prod-ca.crt /app/certs/supabase-prod-ca.crt
LABEL org.opencontainers.image.source="https://github.com/litegraphdb/litegraph" \
      org.opencontainers.image.revision="e1b32136603e158d6f5b0031413eac1ef1ed30f9" \
      org.opencontainers.image.version="9.0.0-existing-schema.1"
ENV LITEGRAPH_CREATE_DEFAULT_RECORDS=false
EXPOSE 8701
ENTRYPOINT ["dotnet", "LiteGraph.Server.dll"]
