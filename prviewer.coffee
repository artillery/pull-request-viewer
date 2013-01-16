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

GitHubAPI = require 'github'
GitHubStrategy = require('passport-github').Strategy
async = require 'async'
express = require 'express'
fs = require 'fs'
http = require 'http'
optimist = require 'optimist'
passport = require 'passport'
path = require 'path'
stylus = require 'stylus'

argv = optimist
  .usage('Usage: $0 settings.json')
  .options('-h', alias: 'host', default: 'localhost')
  .options('-p', alias: 'port', default: 8000)
  .demand(1)
  .argv

settings = JSON.parse fs.readFileSync argv._[0]

# -------------------------------------------------------------------------
# GITHUB OAUTH INITIALIZATION
# -------------------------------------------------------------------------

passport.use new GitHubStrategy({
  clientID: settings.github.clientID
  clientSecret: settings.github.clientSecret
  callbackURL: "http://#{ argv.host }:#{ argv.port }/auth/github/callback"
}, (accessToken, refreshToken, profile, done) ->
  process.nextTick ->
    return done null, { profile: profile, accessToken: accessToken }
)

passport.serializeUser (user, done) -> done null, user
passport.deserializeUser (user, done) -> done null, user

# -------------------------------------------------------------------------
# EXPRESS INITIALIZATION
# -------------------------------------------------------------------------

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

# -------------------------------------------------------------------------
# AUTHENTICATION HANDLERS
# -------------------------------------------------------------------------

app.get '/auth/github', passport.authenticate 'github', scope: 'repo'

app.get '/auth/github/callback',
  passport.authenticate('github', failureRedirect: '/error'),
  (req, res) ->
    res.redirect '/'

app.get '/logout', (req, res) ->
  req.logout()
  res.redirect '/'

ensureAuthenticated = (req, res, next) ->
  if req.isAuthenticated()
    return next()
  else
    res.redirect '/auth/github'

# -------------------------------------------------------------------------
# DASHBOARD
# -------------------------------------------------------------------------

app.get '/', ensureAuthenticated, (req, res) ->
  github = new GitHubAPI(version: '3.0.0')
  github.authenticate type: 'oauth', token: req.user.accessToken

  username = req.user.profile.username

  async.waterfall [

    (cb) ->
      github.pullRequests.getAll {
        user: settings.github.user
        repo: settings.github.repo
      }, cb

    (pulls, cb) ->
      cb null, pulls

  ], (err, pulls) ->
    if err
      res.send 500, "Error: #{ err }"
    else
      res.render 'index',
        settings: settings
        profile: req.user.profile
        pulls: pulls

# -------------------------------------------------------------------------
# SERVER STARTUP
# -------------------------------------------------------------------------

http.createServer(app).listen argv.port, argv.host, ->
  console.log "Pull Request Viewer listening on port http://#{ argv.host }:#{ argv.port }"

