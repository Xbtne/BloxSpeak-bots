FROM alpine:3.19

# Install dependencies
RUN apk add --no-cache curl unzip libc6-compat libgcc libstdc++ ca-certificates

# Install Lune
RUN curl -fsSL https://github.com/lune-org/lune/releases/download/v0.10.5/lune-0.10.5-linux-x86_64.zip -o lune.zip && \
    unzip lune.zip && \
    mv lune /usr/local/bin/lune && \
    chmod +x /usr/local/bin/lune && \
    rm lune.zip

WORKDIR /app
COPY . .

ENV PORT=8080
EXPOSE 8080

CMD ["lune", "run", "bot.luau"]
