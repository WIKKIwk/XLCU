FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src

COPY Directory.Build.props ./
COPY src/Titan.Domain/Titan.Domain.csproj src/Titan.Domain/
COPY src/Titan.Core/Titan.Core.csproj src/Titan.Core/
COPY src/Titan.Infrastructure/Titan.Infrastructure.csproj src/Titan.Infrastructure/
COPY src/Titan.TUI/Titan.TUI.csproj src/Titan.TUI/
COPY src/Titan.Host/Titan.Host.csproj src/Titan.Host/
COPY Titan.slnx ./

RUN dotnet restore src/Titan.Host/Titan.Host.csproj

COPY src/ src/
RUN dotnet publish src/Titan.Host/Titan.Host.csproj \
    -c Release \
    -o /app/publish \
    --self-contained true \
    --runtime linux-x64 \
    /p:PublishSingleFile=true \
    /p:PublishTrimmed=true \
    /p:TrimMode=partial

FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y \
    libicu72 \
    libusb-1.0-0 \
    udev \
    curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash titan

WORKDIR /app

COPY --from=build /app/publish/Titan.Host /app/titan
RUN chmod +x /app/titan

RUN mkdir -p /data /logs && chown -R titan:titan /app /data /logs

USER titan

ENV TITAN_Hardware__ScalePort="/dev/ttyUSB0"
ENV TITAN_Hardware__PrinterDevice="/dev/usb/lp0"

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8080/health/live || exit 1

VOLUME ["/data", "/logs"]

ENTRYPOINT ["/app/titan"]
