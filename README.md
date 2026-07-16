# Laundry Platform V2

Nova plataforma operacional da lavanderia.

## Objetivo desta primeira versão

Esta fundação cria:

- estrutura organizada do projeto;
- autenticação ligada ao Supabase Auth;
- perfis operacionais de staff, sem dados privados;
- clientes, áreas, estações, turnos e tipos de produto;
- programação versionada dos customers;
- estrutura inicial de Roster;
- controle de trolleys por data de envio e data de recebimento;
- exceção rastreável para trolley recebido sem envio registrado;
- auditoria básica;
- regras críticas centralizadas no PostgreSQL.

A produção de Sorting, Finish, Mop, ABS e Reports será criada nas próximas
migrações, depois da revisão sistemática das aplicações antigas.

## Importante

Execute a migração inicialmente em um projeto Supabase novo de desenvolvimento,
por exemplo:

`laundry-v2-dev`

Não execute no banco atualmente usado pelas aplicações em produção.

## Pastas

```text
laundry-platform-v2/
├── frontend/
├── supabase/
│   ├── migrations/
│   ├── seed/
│   ├── functions/
│   └── tests/
└── docs/
```

## Primeiro passo no Supabase

1. Crie ou abra um projeto novo de desenvolvimento.
2. Abra `SQL Editor`.
3. Abra o arquivo:
   `supabase/migrations/202607160001_foundation.sql`
4. Copie todo o conteúdo.
5. Cole no SQL Editor.
6. Clique em `Run`.
7. Depois execute:
   `supabase/seed/202607160001_reference_seed.sql`

## O que ainda não fazer

- Não importar os dados antigos.
- Não apagar o CentralDB atual.
- Não ligar as aplicações atuais ao V2.
- Não criar telas completas antes de revisar as regras antigas.
- Não colocar `service_role`, secret key ou senha do banco no frontend.
