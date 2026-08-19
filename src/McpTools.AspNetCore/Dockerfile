FROM mcr.microsoft.com/dotnet/sdk:10.0.400-noble@sha256:e1ffd2a92ae84c1291bc1b6887501f8af98e6331e7af6d4c8d37168c5e87a64c AS build
WORKDIR /src

COPY NuGet.config ./
COPY src/McpTools.Core/McpTools.Core.csproj src/McpTools.Core/
COPY src/McpTools.AspNetCore/McpTools.AspNetCore.csproj src/McpTools.AspNetCore/
RUN dotnet restore src/McpTools.AspNetCore/McpTools.AspNetCore.csproj

COPY src/McpTools.Core/ src/McpTools.Core/
COPY src/McpTools.AspNetCore/ src/McpTools.AspNetCore/
RUN dotnet publish src/McpTools.AspNetCore/McpTools.AspNetCore.csproj \
    --configuration Release \
    --no-restore \
    --output /app/publish \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0.11-noble@sha256:a4556ed033fa96f984bb7a8d348851cb2d36b1281dd2420070045f664fbb5f94
WORKDIR /app
COPY --from=build --chown=app:app /app/publish ./
USER $APP_UID
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet", "McpTools.AspNetCore.dll"]
