#!/usr/bin/env coffee
#
# Copyright 2012 Artillery Games, Inc. All rights reserved.
#
# This code, and all derivative work, is the exclusive property of Artillery
# Games, Inc. and may not be used without Artillery Games, Inc.'s authorization#
#
# Author: Ian Langworth

express = require 'express'
optimist = require 'optimist'
stylus = require 'stylus'
path = require 'path'
http = require 'http'

argv = optimist
  .usage('Usage: $0 -u githubuser -r reponame -s sekritcookiekey')
  .options('p', alias: 'port', default: 8000)
  .options('s', alias: 'secretkey', demand: true)
  .options('u', alias: 'user', demand: true)
  .options('r', alias: 'repo', demand: true)
  .argv

app = express()

app.configure ->
  app.set 'port', argv.port
  app.set 'views', "#{ __dirname }/views"
  app.set 'view engine', 'hjs'
  app.use express.favicon()
  app.use express.logger 'dev'
  app.use express.bodyParser()
  app.use express.methodOverride()
  app.use express.cookieParser argv.secretkey
  app.use express.session()
  app.use app.router
  app.use stylus.middleware "#{ __dirname }/public"
  app.use express.static path.join "#{ __dirname }/public"

app.configure 'development', ->
  app.use express.errorHandler()

app.get '/', (req, res) ->
  res.render 'index', { title: 'Express' }

http.createServer(app).listen argv.port, ->
  console.log "Pull Request Viewer listening on port #{ argv.port }"

