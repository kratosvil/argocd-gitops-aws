FROM nginx:alpine

# Reuse nginx's built-in envsubst-on-templates entrypoint (normally used for
# config templates) to render the HTML instead, pointing its output at the
# html root. POD_NAME comes from the Kubernetes Downward API at runtime —
# see base/deployment.yaml.
ENV NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/html-templates \
    NGINX_ENVSUBST_TEMPLATE_SUFFIX=.template \
    NGINX_ENVSUBST_OUTPUT_DIR=/usr/share/nginx/html

COPY index.html.template /etc/nginx/html-templates/index.html.template
