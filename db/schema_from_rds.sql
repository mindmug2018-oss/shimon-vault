--
-- PostgreSQL database dump
--

\restrict HPnHa4KLqzDj3MaNPn8WjAjvjuxBTiJ9ZMAmfYp7DE0ousbaNhch2odZhWOV1jk

-- Dumped from database version 16.13
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: auditeventtype; Type: TYPE; Schema: public; Owner: shimonvault
--

CREATE TYPE public.auditeventtype AS ENUM (
    'LOGIN_SUCCESS',
    'LOGIN_FAILURE',
    'LOGOUT',
    'DOC_UPLOAD',
    'DOC_DOWNLOAD',
    'DOC_DELETE',
    'DOC_ACCESS_DENIED',
    'MEETING_CREATE',
    'MEETING_JOIN',
    'MEETING_CANCEL',
    'TOKEN_REPLAY',
    'RATE_LIMIT_HIT',
    'SUSPICIOUS'
);


ALTER TYPE public.auditeventtype OWNER TO shimonvault;

--
-- Name: documentstatus; Type: TYPE; Schema: public; Owner: shimonvault
--

CREATE TYPE public.documentstatus AS ENUM (
    'ACTIVE',
    'DELETED'
);


ALTER TYPE public.documentstatus OWNER TO shimonvault;

--
-- Name: meetingstatus; Type: TYPE; Schema: public; Owner: shimonvault
--

CREATE TYPE public.meetingstatus AS ENUM (
    'SCHEDULED',
    'ACTIVE',
    'EXPIRED',
    'CANCELLED'
);


ALTER TYPE public.meetingstatus OWNER TO shimonvault;

--
-- Name: userrole; Type: TYPE; Schema: public; Owner: shimonvault
--

CREATE TYPE public.userrole AS ENUM (
    'ADMIN',
    'EDITOR',
    'VIEWER'
);


ALTER TYPE public.userrole OWNER TO shimonvault;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: audit_events; Type: TABLE; Schema: public; Owner: shimonvault
--

CREATE TABLE public.audit_events (
    id uuid NOT NULL,
    event_type public.auditeventtype NOT NULL,
    user_id uuid,
    ip_address character varying(45),
    resource character varying(512),
    detail text,
    severity character varying(20),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.audit_events OWNER TO shimonvault;

--
-- Name: documents; Type: TABLE; Schema: public; Owner: shimonvault
--

CREATE TABLE public.documents (
    id uuid NOT NULL,
    filename character varying(255) NOT NULL,
    s3_key character varying(512) NOT NULL,
    content_type character varying(100) NOT NULL,
    size_bytes integer NOT NULL,
    version integer NOT NULL,
    parent_id uuid,
    owner_id uuid NOT NULL,
    status public.documentstatus NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    deleted_at timestamp without time zone
);


ALTER TABLE public.documents OWNER TO shimonvault;

--
-- Name: meetings; Type: TABLE; Schema: public; Owner: shimonvault
--

CREATE TABLE public.meetings (
    id uuid NOT NULL,
    title character varying(255) NOT NULL,
    description text,
    organizer_id uuid NOT NULL,
    join_token character varying(64) NOT NULL,
    status public.meetingstatus NOT NULL,
    scheduled_at timestamp without time zone NOT NULL,
    ends_at timestamp without time zone NOT NULL,
    eventbridge_rule_name character varying(255),
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    archived_at timestamp without time zone
);


ALTER TABLE public.meetings OWNER TO shimonvault;

--
-- Name: participants; Type: TABLE; Schema: public; Owner: shimonvault
--

CREATE TABLE public.participants (
    id uuid NOT NULL,
    meeting_id uuid NOT NULL,
    user_id uuid NOT NULL,
    attended boolean NOT NULL,
    joined_at timestamp without time zone
);


ALTER TABLE public.participants OWNER TO shimonvault;

--
-- Name: users; Type: TABLE; Schema: public; Owner: shimonvault
--

CREATE TABLE public.users (
    id uuid NOT NULL,
    email character varying(255) NOT NULL,
    username character varying(100) NOT NULL,
    hashed_pw character varying(255) NOT NULL,
    role public.userrole NOT NULL,
    is_active boolean NOT NULL,
    suspended boolean NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE public.users OWNER TO shimonvault;

--
-- Name: audit_events audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_pkey PRIMARY KEY (id);


--
-- Name: documents documents_pkey; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_pkey PRIMARY KEY (id);


--
-- Name: meetings meetings_join_token_key; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_join_token_key UNIQUE (join_token);


--
-- Name: meetings meetings_pkey; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_pkey PRIMARY KEY (id);


--
-- Name: participants participants_pkey; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.participants
    ADD CONSTRAINT participants_pkey PRIMARY KEY (id);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


--
-- Name: users users_username_key; Type: CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_username_key UNIQUE (username);


--
-- Name: ix_audit_events_created_at; Type: INDEX; Schema: public; Owner: shimonvault
--

CREATE INDEX ix_audit_events_created_at ON public.audit_events USING btree (created_at);


--
-- Name: ix_audit_events_event_type; Type: INDEX; Schema: public; Owner: shimonvault
--

CREATE INDEX ix_audit_events_event_type ON public.audit_events USING btree (event_type);


--
-- Name: ix_users_email; Type: INDEX; Schema: public; Owner: shimonvault
--

CREATE UNIQUE INDEX ix_users_email ON public.users USING btree (email);


--
-- Name: audit_events audit_events_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.audit_events
    ADD CONSTRAINT audit_events_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- Name: documents documents_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.users(id);


--
-- Name: documents documents_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.documents
    ADD CONSTRAINT documents_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.documents(id);


--
-- Name: meetings meetings_organizer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.meetings
    ADD CONSTRAINT meetings_organizer_id_fkey FOREIGN KEY (organizer_id) REFERENCES public.users(id);


--
-- Name: participants participants_meeting_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.participants
    ADD CONSTRAINT participants_meeting_id_fkey FOREIGN KEY (meeting_id) REFERENCES public.meetings(id);


--
-- Name: participants participants_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shimonvault
--

ALTER TABLE ONLY public.participants
    ADD CONSTRAINT participants_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(id);


--
-- PostgreSQL database dump complete
--

\unrestrict HPnHa4KLqzDj3MaNPn8WjAjvjuxBTiJ9ZMAmfYp7DE0ousbaNhch2odZhWOV1jk

