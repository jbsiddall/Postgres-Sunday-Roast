create extension vector;
create table items (id bigint generated always as identity primary key, embedding vector(3));
insert into items (embedding) values ('[1,2,3]'), ('[4,5,6]');
