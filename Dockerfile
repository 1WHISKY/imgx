FROM glua:latest
# https://github.com/1WHISKY/glua

RUN mkdir -p /out /root/.glua/data
ADD src/ /root/.glua/data/

WORKDIR "/out"
ENTRYPOINT ["/usr/local/bin/lua", "/root/.glua/data/main.lua" ]
