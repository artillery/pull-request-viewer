#!/usr/bin/env coffee
#
# Copyright 2012 Artillery Games, Inc. All rights reserved.
#
# This code, and all derivative work, is the exclusive property of Artillery
# Games, Inc. and may not be used without Artillery Games, Inc.'s authorization#
#
# Author: Ian Langworth
#
# Inspired strongly by https://github.com/jaredhanson/passport-github/blob/master/examples/login/app.js

express = require 'express'
stylus = require 'stylus'
path = require 'path'
http = require 'http'
passport = require 'passport'
optimist = require 'optimist'
fs = require 'fs'

GitHubStrategy = require('passport-github').Strategy

argv = optimist
  .usage('Usage: $0 settings.json')
  .options('-h', alias: 'host', default: 'localhost')
  .options('-p', alias: 'port', default: 8000)
  .demand(1)
  .argv

settings = JSON.parse fs.readFileSync argv._[0]

passport.use new GitHubStrategy({
  clientID: settings.github.clientID
  clientSecret: settings.github.clientSecret
  callbackURL: "http://#{ argv.host }:#{ argv.port }/auth/github/callback"
}, (accessToken, refreshToken, profile, done) ->
  process.nextTick ->
    return done null, profile
)

passport.serializeUser (user, done) ->
  done null, user
passport.deserializeUser (user, done) ->
  done null, user

app = express()

app.configure ->
  app.set 'port', argv.port
  app.set 'views', "#{ __dirname }/views"
  app.set 'view engine', 'hjs'
  app.use express.favicon()
  app.use express.logger 'dev'
  app.use express.bodyParser()
  app.use express.methodOverride()
  app.use express.cookieParser settings.cookieSecret
  app.use express.session secret: settings.sessionSecret
  app.use passport.initialize()
  app.use passport.session()
  app.use app.router
  app.use stylus.middleware "#{ __dirname }/public"
  app.use express.static path.join "#{ __dirname }/public"

app.configure 'development', ->
  app.use express.errorHandler()

app.get '/auth/github', passport.authenticate 'github'

app.get '/auth/github/callback',
  passport.authenticate('github', failureRedirect: '/error'),
  (req, res) ->
    res.redirect '/'

ensureAuthenticated = (req, res, next) ->
  if req.isAuthenticated()
    return next()
  else
    res.redirect '/auth/github'

app.get '/', ensureAuthenticated, (req, res) ->
  res.render 'index',
    settings: settings
    user: req.user

app.get '/logout', (req, res) ->
  req.logout()
  res.redirect '/'

http.createServer(app).listen argv.port, argv.host, ->
  console.log "Pull Request Viewer listening on port http://#{ argv.host }:#{ argv.port }"

