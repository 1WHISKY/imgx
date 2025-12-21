require("glua")


workdir = "/var/lib/docker"
hash_algo = "sha256"
driver = "overlay2"
compress = true
filelist = {}

function indexFiles(dir)
    local result = {}

    local files, folders, extra = file.Find(dir .. "/*", "ROOT")
    local filesSize = 0

    for _, f in pairs(files or {}) do
        local details = file.Details(dir .. "/" .. f, "ROOT")

        if details and details.target then
            result[f] = details.target
            continue
        end

        local size = details and details.size or 0
        result[f] = size
        filesSize = filesSize + size
    end

    for _, folder in pairs(folders or {}) do
        local details = file.Details(dir .. "/" .. folder, "ROOT")

        if details and details.target then
            result[folder] = details.target
            continue
        end

        result[folder] = indexFiles(dir .. "/" .. folder, "ROOT")
        filesSize = filesSize + (result[folder].__dir_size or 0)
    end

    for _, f in pairs(extra or {}) do
        local details = file.Details(dir .. "/" .. f, "ROOT")

        if details and details.target then
            result[f] = details.target
            continue
        end

        result[f] = -1
    end

    if filesSize != 0 then
        result.__dir_size = filesSize
    end

    return result
end

function stripAlgo(str)
    return string.Replace(str, hash_algo .. ":", "")
end



print("Reading images list")


local repo_file = workdir .. "/image/" .. driver .. "/repositories.json"

repos = file.Read(repo_file, "ROOT")
if !repos then print("cant read repo file ", repo_file) os.exit(1) end

repos = util.JSONToTable(repos)

if !repos or !repos.Repositories then print("error parsing repo file ", repo_file) os.exit(1) end
repos = repos.Repositories



images = {}
layers = {} // just used for counting references

for repo, entries in pairs(repos) do
    for t, h in pairs(entries) do

        // de-dupe @sha256 tagged images
        if string.find(t, "@" .. hash_algo .. ":", 1, true) then
            entries[t] = nil

            if !table.HasValue(entries, h) then // restore it, as it was the only one
                entries[t] = h
            end
        end

        // fill tags table
        local hash = stripAlgo(h)
        images[hash] = images[hash] or {}
        images[hash].tags = images[hash].tags or {}

        if !table.HasValue(images[hash].tags, t) then
           table.insert(images[hash].tags, t)
        end
    end
end


print("Parsing image structure")

// fill layers
for hash, v in pairs(images) do
    local i = images[hash]
    i.layers = {}
    i.size = 0

    local image = util.JSONToTable(file.Read( workdir .. "/image/" .. driver .. "/imagedb/content/sha256/" .. hash, "ROOT"))
    if !image then print("error parsing image ", hash, v.tags[1]) continue end

    local diffs = image and image.rootfs and image.rootfs.diff_ids
    if !diffs or !diffs[1] then print("error parsing diffs for image ", hash, v.tags[1]) continue end


    for k, v in pairs(diffs) do
        local l = {}
        i.layers[k] = l

        l.diff = v

        if k == 1 then
           l.chain = stripAlgo(v)  // base layer
        else
            local layer_prev = i.layers[k - 1]
            if layer_prev and layer_prev.chain then
                l.chain = util.SHA256(hash_algo .. ":" .. layer_prev.chain .. " " .. l.diff)
            end
        end

        l.cache = file.Read(workdir .. "/image/" .. driver .. "/layerdb/sha256/" .. l.chain .. "/cache-id", "ROOT")
        l.size = tonumber(file.Read(workdir .. "/image/" .. driver .. "/layerdb/sha256/" .. l.chain .. "/size", "ROOT"))
        i.size = i.size + (l.size or 0)

        i.history = image.history
        i.config = image.config

        layers[v] = layers[v] or {}
        table.insert(layers[v], hash)
    end

end


// find same chains
for hash, image in pairs(images) do
    for k, layer in pairs(image.layers) do
        local search = layer.chain

        for hash_same, image_same in pairs(images) do   // check if the highest chain of a different image is the same
            if hash_same == hash then continue end

            local highest = image_same.layers[#image_same.layers].chain

            if highest == search then
               layer.same_as = hash_same
               break
            end
        end


    end
end

print("Indexing files")

local count = 0

for hash, image in pairs(images) do
    count = count + 1
    MsgN("image ", count, " of ", table.Count(images), ":\t", image.tags[1])

    for k, layer in pairs(image.layers) do
        if !filelist[layer.cache] then
            filelist[layer.cache] = indexFiles(workdir .. "/" .. driver .. "/" .. layer.cache .. "/diff")
        end

        layer.os_release = file.Read(workdir .. "/" .. driver .. "/" .. layer.cache .. "/diff/etc/os-release", "ROOT")

        if layer.os_release then
            layer.os = string.match(layer.os_release, 'PRETTY_NAME%s*=%s*"(.-)"')
            layer.os = layer.os or string.match(layer.os_release, 'PRETTY_NAME%s*=%s*(%S+)')
            layer.os = layer.os or "Unknown OS"
        end
    end
end


print("Generating output")

local imagesSize = 0

for k, v in pairs(images) do
   imagesSize = imagesSize + (v.size or 0)
end

data = {
    datadir = workdir .. "/" .. driver,
    images = images,
    imagesizetotal = imagesSize,
    files = filelist,
    layers = layers
}

json = util.TableToJSON(data)

if compress then
    print("Compressing")
    zlib = require("zlib")
    compressed = zlib.deflate()(json, "finish")
    compressed = util.Base64Encode(compressed, true)

    pako = file.Read("pako.min.js", "DATA")
    if !pako then compress = false end
    if string.len(pako or json) + string.len(compressed) > string.len(json) then compress = false end
end


print("Writing file")

html = string.Split(file.Read("index.html", "DATA") or "", "<!-- data goes here -->")
if #html != 2 then print("error reading index.html") os.exit(1) end

out = file.Open("output.html", "wb", "ROOT")
if !out then print("error creating output file") os.exit(1) end

out:Write(html[1])

if compress then
    out:Write("<script>")
    out:Write(pako)
    out:Write("</script>\n")

    out:Write("<script> var compressed = \"")
    out:Write(compressed)
    out:Write("\"</script>\n")
else
    out:Write("<script> var data = ")
    out:Write(json)
    out:Write("</script>\n")
end

out:Write(html[2])

out:Close()
print("Wrote output.html")
