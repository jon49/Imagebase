# Imagebase

This is a server that does basic CRDT (last write wins) copying of your data
from your device.

## About

This server aims to be a back end for my offline-first applications. It enables
me to focus mostly on the front end logic and keep the back end all the same. It
does simple authentication with username/password and server-side cookies. It
uses Sqlite to keep things simple.

It uses V as I wanted to learn it and find it to be a fairly elegant language (I
always say, "V is a better Go").

## Etymology

The naming of Imagebase base follows the tradition of Firebase / Supabase /
Pocketbase. I'm not sure if it will ever be as full featured as those great
projects. But I will continue to build it out as it fits my needs.

Image references the concept of taking an image of your computer for back up
purposes. The image doesn't do much, just the bare minimum and your project is
expected to do most of the heavy lifting.

