# imgx

Explore docker images and layers

# What it does

Generate a static html showcasing your locally pulled docker images.  
Explore layers and files interactively, easily find image bases and common layers.  
  
View the [example output](https://1whisky.github.io/imgx/)

# Usage

```
docker run --rm -it -v /var/lib/docker:/var/lib/docker:ro -v $PWD:/out --network none ghcr.io/1whisky/imgx:latest
```
Requires docker with the overlay2 driver.
